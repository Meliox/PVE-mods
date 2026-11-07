use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(sleep);

use lib "$ENV{AMD_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Collector::Amd qw(get_amd_gpu_devices collector_for_amd_device);
use PVE::PVEMods::Config qw(%config);

my $dir = tempdir(CLEANUP => 1);
sub write_file {
    my ($path, $value) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $value;
    close $fh or die "$path: $!";
}
make_path("$dir/drm", "$dir/drivers/amdgpu", "$dir/drivers/vfio-pci");
sub add_device {
    my ($card, $pci, $vendor, $driver) = @_;
    my $path = "$dir/pci/$pci";
    make_path("$path/hwmon/hwmon7", "$dir/drm/$card");
    symlink($path, "$dir/drm/$card/device") or die $!;
    symlink("$dir/drivers/$driver", "$path/driver") or die $!;
    write_file("$path/vendor", $vendor);
    write_file("$path/device", '0x1900');
    write_file("$path/hwmon/hwmon7/name", 'amdgpu');
    return $path;
}
my $apu = add_device('card3', '0000:c6:00.0', '0x1002', 'amdgpu');
my $discrete = add_device('card9', '0000:08:00.0', '0x1002', 'amdgpu');
add_device('card0', '0000:00:02.0', '0x8086', 'amdgpu');
add_device('card5', '0000:09:00.0', '0x1002', 'vfio-pci');
make_path("$dir/drm/card11");
symlink($apu, "$dir/drm/card11/device") or die $!;
write_file("$discrete/product_name", 'Radeon Test GPU');

local $config{debug}{amd_mode} = 0;
my @devices = get_amd_gpu_devices("$dir/drm");
is(scalar @devices, 2, 'AMD discovery excludes Intel, passthrough and duplicate PCI devices');
my ($a) = grep { $_->{pci_address} eq '0000:c6:00.0' } @devices;
my ($d) = grep { $_->{pci_address} eq '0000:08:00.0' } @devices;
is($a->{history_id}, 'pci0000c6000', 'PCI history ID is stable');
like($a->{card}, qr/^amd\d+$/, 'AMD state filename cannot be classified as Intel');
is($a->{name}, 'AMD GPU (0x1900)', 'missing product name uses PCI identity');
is($d->{name}, 'Radeon Test GPU', 'driver product name retained');
write_file("$apu/gpu_busy_percent", '0');
write_file("$apu/mem_info_vram_used", 67108864);
write_file("$apu/mem_info_vram_total", 4294967296);
write_file("$apu/mem_info_gtt_used", 134217728);
write_file("$apu/mem_info_gtt_total", 8589934592);
my $hw = "$apu/hwmon/hwmon7";
for my $entry (
    ['temp1_input',40000], ['temp1_label','edge'], ['temp1_max',90000],
    ['temp1_crit',100000], ['temp2_input',55000], ['temp2_label','junction'],
    ['power1_average',10041000], ['power1_input',123000000],
    ['power1_label','PPT'], ['freq1_input',800000000], ['fan1_input',0],
) { write_file("$hw/$entry->[0]", $entry->[1]); }
my $stats = PVE::PVEMods::Collector::Amd::collect_amd_stats($a);
is($stats->{utilization}{gpu}, 0, 'idle utilization is valid zero');
ok(!exists $stats->{utilization}{memory}, 'missing controller metric is not zero');
is($stats->{memory}{used}, 64, 'VRAM bytes converted to MiB');
is($stats->{memory}{total}, 4096, 'VRAM allocation total');
is($stats->{gtt}{used}, 128, 'GTT remains separate from VRAM');
is($stats->{gtt}{unit}, 'MiB', 'memory unit travels with values');
is($stats->{temperature}{gpu}, 40, 'millidegrees converted to Celsius');
is($stats->{sensors}{temp2}{value}, 55, 'additional temperature retained');
is($stats->{sensors}{temp1}{crit}, 100, 'temperature thresholds converted');
is($stats->{frequency}{actual}, 800, 'Hz converted to MHz');
is($stats->{power}{draw}, 10.041, 'microwatts converted; average preferred to input');
is($stats->{power}{label}, 'PPT', 'power sensor scope label retained');
is_deeply($stats->{fan}, { speed => 0, unit => 'RPM' }, 'fan is RPM, not percent');
my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    write_file("$apu/gpu_busy_percent", '101');
    for (1..2) {
        my $bad = PVE::PVEMods::Collector::Amd::collect_amd_stats($a);
        ok(!exists $bad->{utilization}{gpu}, 'invalid percent omitted');
    }
}
is(scalar @warnings, 1, 'repeated invalid readings warn once');
write_file("$apu/gpu_busy_percent", '50');
is(PVE::PVEMods::Collector::Amd::collect_amd_stats($a)->{utilization}{gpu}, 50, 'reading recovers');
write_file("$hw/temp1_input", '-5000');
is(PVE::PVEMods::Collector::Amd::collect_amd_stats($a)->{temperature}{gpu}, -5, 'signed temperatures supported');
is_deeply(PVE::PVEMods::Collector::Amd::collect_amd_stats($d), {}, 'device with no supported sensors has no fabricated values');

write_file("$dir/devices.json", encode_json(\@devices));
{
    local $config{debug}{amd_mode} = 1;
    local $config{debug}{amd_devices_file} = "$dir/devices.json";
    is_deeply([get_amd_gpu_devices()], \@devices, 'debug device fixture round-trips');
    write_file("$dir/devices.json", '{}');
    eval { get_amd_gpu_devices() };
    like($@, qr/device array/, 'invalid debug data fails explicitly');
}

{
    no warnings 'redefine';
    local *PVE::PVEMods::Collector::Amd::setup_collector_signals = sub {};
    local *PVE::PVEMods::Collector::Amd::safe_write_json = sub {
        my ($file, $data) = @_;
        like($file, qr/stats-amd\d+\.json\.tmp$/, 'AMD atomic state publication filename');
        is($data->{$a->{card}}{status}, 'unavailable', 'removed device publishes unavailable');
        is_deeply($data->{$a->{card}}{stats}, {}, 'removed device clears stale readings');
        die "publication tested\n";
    };
    my %removed = (%$a, sysfs_path => "$dir/removed");
    eval { collector_for_amd_device(\%removed) };
    like($@, qr/publication tested/, 'collector removal branch exercised without a real process');
}

{
    local $PVE::PVEMods::Collector::Amd::pve_mods_working_dir = $dir;
    local $config{gpu}{gpu_history} = 0;
    local $config{intervals}{data_pull} = 1;
    my $file = "$dir/stats-$a->{card}.json";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        collector_for_amd_device($a);
        POSIX::_exit(1);
    }
    for (1..100) {
        last if -f $file;
        sleep 0.05;
    }
    ok(-f $file, 'real collector publishes a complete JSON file');
    if (-f $file) {
        open my $fh, '<', $file or die $!;
        local $/;
        my $data = decode_json(<$fh>);
        close $fh;
        is($data->{$a->{card}}{stats}{utilization}{gpu}, 50, 'real loop publishes normalized readings');
    }
    kill 'TERM', $pid;
    waitpid($pid, 0);
    is($? >> 8, 0, 'collector handles SIGTERM cleanly');
    ok(!-e "$file.tmp", 'atomic publication leaves no temporary file');
}
done_testing();
