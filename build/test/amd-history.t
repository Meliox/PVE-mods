use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use lib "$ENV{AMD_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Store qw(update_amd_gpu_rrd gpu_rrd_path);
use PVE::PVEMods::Config qw(%config $RRD_BASE $RRD_SOCKET);
use RRDs;
use PVE::API2::PVEMods_SensorInfo;

my $dir = tempdir(CLEANUP => 1);
local $PVE::PVEMods::Store::RRD_BASE = $dir;
local $PVE::PVEMods::Store::RRD_SOCKET = "$dir/no-daemon";
local $config{gpu}{gpu_history} = 0;
my $stats = { utilization => { gpu => 0 }, memory => { used => 64, total => 4096 },
    gtt => { used => 128, total => 8192 }, frequency => { actual => 800 },
    power => { draw => 10.041 }, temperature => { gpu => 40 }, fan => { speed => 0, unit => 'RPM' } };
update_amd_gpu_rrd('amdtest', $stats);
ok(!-e gpu_rrd_path('amdtest'), 'disabled history does not create files');
$config{gpu}{gpu_history} = 1;
my @updates;
my $missing = {};
{
    no warnings 'redefine';
    local *RRDs::update = sub { push @updates, [@_] };
    update_amd_gpu_rrd('amdtest', $stats);
    update_amd_gpu_rrd('amdtest', $missing);
}
my $path = gpu_rrd_path('amdtest');
ok(-f $path, 'AMD history created in isolated directory');
my $info = RRDs::info($path);
ok(!RRDs::error(), 'RRD schema valid');
for my $field (qw(gpu_util mem_util mem_used mem_total gtt_used gtt_total freq_act power_draw temp_gpu fan_rpm)) {
    ok(exists $info->{"ds[$field].type"}, "history field $field exists");
}
is($updates[0][-1], 'N:0:U:64:4096:128:8192:800:10.041:40:0', 'history units match live samples and zeroes are retained');
is($updates[1][-1], 'N:U:U:U:U:U:U:U:U:U:U', 'missing samples become unknown rather than zero');
is_deeply($missing, {}, 'history writer does not mutate collector readings');
update_amd_gpu_rrd('amdtest', $stats);
ok(!RRDs::error(), 'real AMD RRD update succeeds');
my $latest = RRDs::info($path);
ok(!RRDs::error(), 'updated AMD RRD can be read');
is($latest->{'ds[gpu_util].last_ds'}, 0, 'real RRD stores zero GPU utilization');
is($latest->{'ds[fan_rpm].last_ds'}, 0, 'real RRD stores zero fan RPM');
my $file = "$dir/stats-amd3.json";
open my $fh, '>', $file or die $!;
print {$fh} encode_json({ amd3 => { name => 'Radeon Test', stats => $stats } });
close $fh;
my $merged = PVE::API2::PVEMods_SensorInfo::_merge_graphics_files([$file]);
is($merged->{Graphics}{AMD}{amd3}{card}, 'amd3', 'API merges AMD into its own vendor group');
is($merged->{Graphics}{AMD}{amd3}{stats}{fan}{unit}, 'RPM', 'AMD fan data retains RPM semantics');
ok(!keys %{$merged->{Graphics}{Intel}}, 'AMD data never becomes Intel data');
{
    local $PVE::API2::PVEMods_SensorInfo::stats_dir = $dir;
    local $config{gpu}{amd_enabled} = 1;
    local $config{gpu}{intel_enabled} = 0;
    local $config{gpu}{nvidia_enabled} = 0;
    my $first = PVE::API2::PVEMods_SensorInfo::_load_graphics_data();
    is($first->{Graphics}{AMD}{amd3}{stats}{utilization}{gpu}, 0, 'API loads initial sample');
    my $mtime = (stat($file))[9];
    open my $next, '>', "$file.tmp" or die $!;
    print {$next} encode_json({ amd3 => { name => 'Radeon Test', stats => { utilization => { gpu => 50 } } } });
    close $next;
    utime($mtime, $mtime, "$file.tmp") or die $!;
    rename("$file.tmp", $file) or die $!;
    my $second = PVE::API2::PVEMods_SensorInfo::_load_graphics_data();
    is($second->{Graphics}{AMD}{amd3}{stats}{utilization}{gpu}, 50, 'atomic replacement within same mtime second refreshes API cache');
}
done_testing();
