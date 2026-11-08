use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use POSIX ();
use Time::HiRes qw(sleep);

use lib "$ENV{AMD_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Collector::Nvidia qw(get_nvidia_gpu_devices collector_for_nvidia_devices);
use PVE::PVEMods::Config qw(%config);
use PVE::PVEMods::Store qw(update_nvidia_gpu_rrd gpu_rrd_path);
use PVE::API2::PVEMods_SensorInfo;
use RRDs;

my $dir = tempdir(CLEANUP => 1);
sub write_file {
    my ($path, $value) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $value;
    close $fh or die "$path: $!";
}

my $parse = \&PVE::PVEMods::Collector::Nvidia::_parse_nvidia_gpu_line;

# ---- Device discovery (nvidia-smi --query-gpu=index,name,pci.bus_id) -------
write_file("$dir/devices.csv", join("\n",
    'index, name, pci.bus_id',
    '0, NVIDIA GeForce RTX 3080, 00000000:01:00.0',
    '1, NVIDIA Tesla T4, 00000000:0A:00.0',
    '',
));
{
    local $config{debug}{nvidia_mode} = 1;
    local $config{debug}{nvidia_devices_file} = "$dir/devices.csv";
    my @devices = get_nvidia_gpu_devices();
    is(scalar @devices, 2, 'discovery returns one entry per GPU, skipping the header');
    is($devices[0]{index}, 0, 'first GPU index');
    is($devices[0]{name}, 'NVIDIA GeForce RTX 3080', 'GPU name trimmed');
    is($devices[0]{history_id}, 'pci000001000', 'history id derived from PCI bus id');
    is($devices[1]{index}, 1, 'second GPU index');
    is($devices[1]{history_id}, 'pci00000a000', 'PCI bus id is case-insensitive');

    write_file("$dir/devices-nopci.csv", "index, name\n0, NVIDIA Test\n");
    local $config{debug}{nvidia_devices_file} = "$dir/devices-nopci.csv";
    my @nopci = get_nvidia_gpu_devices();
    is(scalar @nopci, 1, 'listing without PCI bus id still discovers the GPU');
    is($nopci[0]{history_id}, 'nvidia0', 'history id falls back to the index');

    write_file("$dir/devices-header.csv", "index, name, pci.bus_id\n");
    local $config{debug}{nvidia_devices_file} = "$dir/devices-header.csv";
    is(scalar(my @none = get_nvidia_gpu_devices()), 0, 'header-only listing yields no devices');

    write_file("$dir/devices-bad.csv", "index, name, pci.bus_id\nnonsense\n");
    local $config{debug}{nvidia_devices_file} = "$dir/devices-bad.csv";
    is(scalar(my @bad = get_nvidia_gpu_devices()), 0, 'malformed rows are ignored');
}

# ---- Stats parsing (nvidia-smi --format=csv,nounits) -----------------------
my $line = '0, NVIDIA GeForce RTX 3080, 54, 12, 7, 1024, 10240, 95.50, 320.00, 35';
my $stats = $parse->($line);
is($stats->{index}, 0, 'index parsed as a number');
is($stats->{name}, 'NVIDIA GeForce RTX 3080', 'name parsed');
is($stats->{temperature}{gpu}, 54, 'temperature parsed');
is($stats->{temperature}{unit}, '°C', 'temperature unit travels with values');
is($stats->{utilization}{gpu}, 12, 'GPU utilization parsed');
is($stats->{utilization}{memory}, 7, 'memory controller utilization parsed');
is($stats->{utilization}{unit}, '%', 'utilization unit');
is($stats->{memory}{used}, 1024, 'memory used parsed');
is($stats->{memory}{total}, 10240, 'memory total parsed');
is($stats->{memory}{unit}, 'MiB', 'memory unit');
is($stats->{power}{draw}, 95.5, 'power draw parsed');
is($stats->{power}{limit}, 320, 'power limit parsed');
is($stats->{power}{unit}, 'W', 'power unit');
is($stats->{fan}{speed}, 35, 'fan speed parsed');
is($stats->{fan}{unit}, '%', 'NVIDIA fan speed is a percentage');

my $idle = $parse->('1, NVIDIA Tesla T4, 30, 0, 0, 0, 15360, 0.00, 70.00, 0');
is($idle->{utilization}{gpu}, 0, 'idle utilization is a valid zero');
is($idle->{fan}{speed}, 0, 'zero fan speed is retained');
is($idle->{memory}{used}, 0, 'zero memory use is retained');
is(scalar($parse->('0, too, few, fields')), undef, 'short rows are rejected');
is(scalar($parse->('')), undef, 'empty rows are rejected');

# nvidia-smi reports "[N/A]" for sensors the GPU does not have (e.g. passively cooled cards)
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $na = $parse->('2, NVIDIA Tesla P4, 40, 1, 0, 100, 7680, [N/A], 75.00, [N/A]');
    ok(!exists $na->{fan}, 'unsupported fan sensor is omitted rather than reported as 0%');
    ok(!exists $na->{power}{draw}, 'unsupported power reading is omitted');
    is($na->{power}{limit}, 75, 'supported readings in the same group are kept');
    is($na->{temperature}{gpu}, 40, 'other groups are unaffected');
    is_deeply(\@warnings, [], 'unsupported sensors do not warn');

    my $none = $parse->('3, NVIDIA Test, [Not Supported], [N/A], [N/A], [N/A], [N/A], [N/A], [N/A], [N/A]');
    is($none->{name}, 'NVIDIA Test', 'GPU with no supported sensors is still reported');
    is_deeply([sort keys %$none], [qw(index name)], 'no readings are fabricated');
    is(scalar($parse->('[N/A], NVIDIA Test, 1, 1, 1, 1, 1, 1, 1, 1')), undef, 'row without a valid index is rejected');
}

# ---- Collector (debug output fixture) --------------------------------------
my $output = join("\n",
    'index, name, temperature.gpu [C], utilization.gpu [%], utilization.memory [%], memory.used [MiB], memory.total [MiB], power.draw [W], power.limit [W], fan.speed [%]',
    $line,
    '1, NVIDIA Tesla T4, 30, 0, 0, 0, 15360, 0.00, 70.00, 0',
    '',
);
my $devices = [
    { index => 0, name => 'GeForce Override', history_id => 'pci000001000' },
    { index => 1, name => 'NVIDIA Tesla T4', history_id => 'pci00000a000' },
];
{
    my $work = tempdir(CLEANUP => 1);
    write_file("$work/output.csv", $output);
    local $PVE::PVEMods::Collector::Nvidia::pve_mods_working_dir = $work;
    local $config{debug}{nvidia_mode} = 1;
    local $config{debug}{nvidia_output_file} = "$work/output.csv";
    local $config{gpu}{gpu_history} = 0;

    is(PVE::PVEMods::Collector::Nvidia::_get_and_write_nvidia_stats($devices), 2, 'both GPUs are collected');
    for my $i (0, 1) {
        ok(-s "$work/stats-nvidia$i.json", "state file written for GPU $i");
    }
    open my $fh, '<', "$work/stats-nvidia0.json" or die $!;
    my $data = decode_json(do { local $/; <$fh> });
    close $fh;
    is($data->{gpu0}{name}, 'GeForce Override', 'device name comes from discovery');
    is($data->{gpu0}{history_id}, 'pci000001000', 'history id comes from discovery');
    is($data->{gpu0}{index}, 0, 'index stored');
    is($data->{gpu0}{stats}{utilization}{gpu}, 12, 'stats stored');
    is($data->{gpu0}{stats}{fan}{speed}, 35, 'fan stats stored');

    # A GPU the discovery did not report falls back to its stats name and index id.
    is(PVE::PVEMods::Collector::Nvidia::_get_and_write_nvidia_stats([]), 2, 'collection works without discovery data');
    open $fh, '<', "$work/stats-nvidia1.json" or die $!;
    $data = decode_json(do { local $/; <$fh> });
    close $fh;
    is($data->{gpu1}{name}, 'NVIDIA Tesla T4', 'name falls back to the nvidia-smi name');
    is($data->{gpu1}{history_id}, 'nvidia1', 'history id falls back to the index');

    write_file("$work/output.csv", "header only\n");
    is(PVE::PVEMods::Collector::Nvidia::_get_and_write_nvidia_stats($devices), 0, 'header-only output collects nothing');
}

# ---- History (RRD) ---------------------------------------------------------
my $rrd_dir = tempdir(CLEANUP => 1);
{
    local $PVE::PVEMods::Store::RRD_BASE = $rrd_dir;
    local $PVE::PVEMods::Store::RRD_SOCKET = "$rrd_dir/no-daemon";
    local $config{gpu}{gpu_history} = 0;
    update_nvidia_gpu_rrd('nvidiatest', $stats);
    ok(!-e gpu_rrd_path('nvidiatest'), 'disabled history does not create files');

    $config{gpu}{gpu_history} = 1;
    my @updates;
    {
        no warnings 'redefine';
        local *RRDs::update = sub { push @updates, [@_] };
        update_nvidia_gpu_rrd('nvidiatest', $stats);
        update_nvidia_gpu_rrd('nvidiatest', {});
    }
    my $path = gpu_rrd_path('nvidiatest');
    ok(-f $path, 'NVIDIA history file created in isolated directory');
    my $info = RRDs::info($path);
    ok(!RRDs::error(), 'RRD schema valid');
    for my $field (qw(gpu_util mem_util mem_used mem_total power_draw power_limit temp_gpu fan_speed)) {
        ok(exists $info->{"ds[$field].type"}, "history field $field exists");
    }
    is($updates[0][-1], 'N:12:7:1024:10240:95.5:320:54:35', 'history values follow the schema order');
    is($updates[1][-1], 'N:U:U:U:U:U:U:U:U', 'missing samples become unknown rather than zero');
    update_nvidia_gpu_rrd('nvidiatest', $idle);
    ok(!RRDs::error(), 'real RRD update succeeds');
    is(RRDs::info($path)->{'ds[gpu_util].last_ds'}, 0, 'real RRD stores zero GPU utilization');
}

# ---- API merge -------------------------------------------------------------
{
    my $file = "$dir/stats-nvidia0.json";
    write_file($file, encode_json({ gpu0 => { name => 'NVIDIA Test', index => 0, stats => $stats } }));
    my $merged = PVE::API2::PVEMods_SensorInfo::_merge_graphics_files([$file]);
    is($merged->{Graphics}{NVIDIA}{gpu0}{card}, 'nvidia0', 'API merges NVIDIA into its own vendor group');
    is($merged->{Graphics}{NVIDIA}{gpu0}{stats}{fan}{unit}, '%', 'NVIDIA fan data retains percent semantics');
    ok(!keys %{$merged->{Graphics}{Intel}}, 'NVIDIA data never becomes Intel data');
    ok(!keys %{$merged->{Graphics}{AMD}}, 'NVIDIA data never becomes AMD data');
    is(${$merged->{enable_fans}}, 1, 'fan data enables the GPU fan row');
}

# ---- Collector loop --------------------------------------------------------
{
    my $work = tempdir(CLEANUP => 1);
    write_file("$work/output.csv", $output);
    local $PVE::PVEMods::Collector::Nvidia::pve_mods_working_dir = $work;
    local $config{debug}{nvidia_mode} = 1;
    local $config{debug}{nvidia_output_file} = "$work/output.csv";
    local $config{gpu}{gpu_history} = 0;
    local $config{intervals}{data_pull} = 1;
    my $file = "$work/stats-nvidia0.json";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        collector_for_nvidia_devices($devices);
        POSIX::_exit(1);
    }
    for (1..100) {
        last if -s $file && -s "$work/stats-nvidia1.json";
        sleep 0.05;
    }
    ok(-s $file, 'collector publishes a state file');
    if (-s $file) {
        open my $fh, '<', $file or die $!;
        my $data = decode_json(do { local $/; <$fh> });
        close $fh;
        is($data->{gpu0}{stats}{temperature}{gpu}, 54, 'real loop publishes parsed readings');
    }
    kill 'TERM', $pid;
    waitpid($pid, 0);
    is($? >> 8, 0, 'collector handles SIGTERM cleanly');
}
done_testing();
