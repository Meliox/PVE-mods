use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use POSIX ();
use Time::HiRes qw(sleep);

use lib "$ENV{AMD_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Collector::Intel qw(get_intel_gpu_devices collector_for_intel_device);
use PVE::PVEMods::Config qw(%config);
use PVE::PVEMods::Store qw(update_intel_gpu_rrd gpu_rrd_path);
use PVE::API2::PVEMods_SensorInfo;
use RRDs;

my $dir = tempdir(CLEANUP => 1);
sub write_file {
    my ($path, $value) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $value;
    close $fh or die "$path: $!";
}

my $parse = \&PVE::PVEMods::Collector::Intel::_parse_intel_gpu_json;
my $extract = \&PVE::PVEMods::Collector::Intel::_extract_intel_json_objects;

# ---- Device discovery (intel_gpu_top -L fixture) ---------------------------
write_file("$dir/devices.txt", join("\n",
    'card0  Intel Alderlake_n (Gen12)  pci:vendor=8086,device=46D0,card=0',
    'card1  Intel Dg2 (Gen12)  pci:vendor=8086,device=56A0,card=1',
    'card2  NVIDIA Something  pci:vendor=10DE,device=2204,card=2',
    'card3  AMD Radeon  pci:vendor=1002,device=1900,card=3',
    'not a device line',
    ''));
{
    local $config{debug}{intel_mode} = 1;
    local $config{debug}{intel_devices_file} = "$dir/devices.txt";
    my @devices = get_intel_gpu_devices();
    is(scalar @devices, 2, 'discovery keeps only Intel vendor devices');
    is_deeply([map { $_->{card} } @devices], [qw(card0 card1)], 'cards are kept in listing order');
    is($devices[0]{name}, 'Intel Alderlake_n (Gen12)', 'device name retained');
    is($devices[0]{path}, 'pci:vendor=8086,device=46D0,card=0', 'device path retained');
    is($devices[0]{drm_path}, '/dev/dri/card0', 'DRM node derived from card name');
    like($devices[0]{history_id}, qr/^(?:card0|pci[0-9a-f]{9})$/, 'history id is card name or PCI based');
    like($devices[1]{history_id}, qr/^[a-zA-Z0-9]+$/, 'history id is a valid RRD file name');

    write_file("$dir/devices-lower.txt", "card0  Intel Test  pci:vendor=8086,device=1234,card=0\n");
    local $config{debug}{intel_devices_file} = "$dir/devices-lower.txt";
    is(scalar(my @one = get_intel_gpu_devices()), 1, 'single device fixture');

    write_file("$dir/devices-empty.txt", '');
    local $config{debug}{intel_devices_file} = "$dir/devices-empty.txt";
    is(scalar(my @none = get_intel_gpu_devices()), 0, 'empty listing yields no devices');
}
{
    # Missing CAP_PERFMON: intel_gpu_top prints an error instead of a device list.
    write_file("$dir/devices-perm.txt", "Failed to initialize PMU! (Permission denied)\n");
    local $config{debug}{intel_mode} = 1;
    local $config{debug}{intel_devices_file} = "$dir/devices-perm.txt";
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    is(scalar(my @none = get_intel_gpu_devices()), 0, 'permission error yields no devices');
    is(scalar @warnings, 1, 'permission error is reported once');
    like($warnings[0] // '', qr/CAP_PERFMON/, 'warning explains how to fix the permission');
}

# ---- Stats parsing ---------------------------------------------------------
my $sample = {
    period => { duration => 1000.0, unit => 'ms' },
    frequency => { requested => 1200.5, actual => 1150.25, unit => 'MHz' },
    interrupts => { count => 321.0, unit => 'irq/s' },
    'rc6' => { value => 87.5, unit => '%' },
    power => { GPU => 3.25, Package => 11.5, unit => 'W' },
    engines => {
        'Render/3D/0' => { busy => 12.5, sema => 1.0, wait => 2.0, unit => '%' },
        'Blitter/0'   => { busy => 0.0, sema => 0.0, wait => 0.0, unit => '%' },
        'Video/0'     => { busy => 45.0, sema => 0.0, wait => 0.0, unit => '%' },
        'VideoEnhance/0' => { busy => 5.0, sema => 0.0, wait => 0.0, unit => '%' },
    },
};
my $stats = $parse->($sample);
is($stats->{frequency}{actual}, 1150.25, 'actual frequency parsed');
is($stats->{frequency}{requested}, 1200.5, 'requested frequency parsed');
is($stats->{frequency}{unit}, 'MHz', 'frequency unit retained');
is($stats->{rc6}{value}, 87.5, 'RC6 residency parsed');
is($stats->{power}{GPU}, 3.25, 'GPU power parsed');
is($stats->{power}{Package}, 11.5, 'package power parsed');
is($stats->{engines}{'Render/3D'}{busy}, 12.5, 'engine instance suffix is tolerated');
is($stats->{engines}{Blitter}{busy}, 0, 'idle engine reports zero');
is($stats->{engines}{Video}{busy}, 45, 'video engine parsed');
is($stats->{engines}{VideoEnhance}{busy}, 5, 'video enhance engine parsed');
is($stats->{engines}{'Render/3D'}{sema}, 1, 'semaphore wait parsed');
is_deeply($stats->{clients}, {}, 'client list is not collected');

my $plain = $parse->({ engines => { 'Render/3D' => { busy => 7 }, Video => { busy => 9 } } });
is($plain->{engines}{'Render/3D'}{busy}, 7, 'engine without instance suffix parsed');
is($plain->{engines}{Blitter}{busy}, 0, 'missing engine defaults to zero');
is($plain->{frequency}{actual}, 0, 'missing frequency defaults to zero');
is($plain->{power}{unit}, 'W', 'missing power unit defaults to W');
is($plain->{rc6}{unit}, '%', 'missing rc6 unit defaults to %');
is(scalar($parse->('not a hash')), undef, 'non-object sample rejected');
is(scalar($parse->(undef)), undef, 'undefined sample rejected');
ok(defined $parse->({}), 'empty sample still produces normalized stats');

# ---- JSON stream extraction ------------------------------------------------
my $obj1 = encode_json({ n => 1, engines => { Video => { busy => 1 } } });
my $obj2 = encode_json({ n => 2 });
{
    my ($buf, $started) = ("[\n$obj1,\n$obj2,\n", 0);
    my @objs = $extract->(\$buf, \$started);
    is_deeply([map { $_->{n} } @objs], [1, 2], 'complete objects are extracted in order');
    ok($started, 'leading bracket is consumed');
    is($buf, '', 'buffer is drained');
}
{
    my ($buf, $started) = ('', 0);
    my @got;
    my $stream = "[\n$obj1,\n$obj2,\n";
    # Feed the stream in small chunks, splitting objects mid-way.
    for my $chunk (unpack('(a7)*', $stream)) {
        $buf .= $chunk;
        push @got, $extract->(\$buf, \$started);
    }
    is_deeply([map { $_->{n} } @got], [1, 2], 'objects split across reads are reassembled');
}
{
    my ($buf, $started) = ("[\n$obj1,\n" . substr($obj2, 0, 5), 0);
    my @objs = $extract->(\$buf, \$started);
    is(scalar @objs, 1, 'partial trailing object is held back');
    like($buf, qr/^\{/, 'partial object stays in the buffer');
    $buf .= substr($obj2, 5);
    is(scalar(my @rest = $extract->(\$buf, \$started)), 1, 'object completes on next read');
}
{
    my ($buf, $started) = ("intel_gpu_top: warning\n", 0);
    my @objs = $extract->(\$buf, \$started);
    is(scalar @objs, 0, 'nothing is extracted before the stream starts');
    ok(!$started, 'stream is not started by stray text');
}
{
    my ($buf, $started) = ("[\nwarning: noisy line\n$obj1,\n", 0);
    my @objs = $extract->(\$buf, \$started);
    is_deeply([map { $_->{n} } @objs], [1], 'stray text between objects is skipped');
}
{
    my ($buf, $started) = ('[' . ('x' x (PVE::PVEMods::Collector::Intel::MAX_INTEL_JSON_BUFFER + 10)), 0);
    my @objs = $extract->(\$buf, \$started);
    is(scalar @objs, 0, 'oversized garbage yields no objects');
    is($buf, '', 'oversized garbage is discarded');
}

# ---- History (RRD) ---------------------------------------------------------
my $rrd_dir = tempdir(CLEANUP => 1);
{
    local $PVE::PVEMods::Store::RRD_BASE = $rrd_dir;
    local $PVE::PVEMods::Store::RRD_SOCKET = "$rrd_dir/no-daemon";
    local $config{gpu}{gpu_history} = 0;
    update_intel_gpu_rrd('inteltest', $stats);
    ok(!-e gpu_rrd_path('inteltest'), 'disabled history does not create files');

    $config{gpu}{gpu_history} = 1;
    my @updates;
    {
        no warnings 'redefine';
        local *RRDs::update = sub { push @updates, [@_] };
        update_intel_gpu_rrd('inteltest', $stats);
        update_intel_gpu_rrd('inteltest', {});
    }
    my $path = gpu_rrd_path('inteltest');
    ok(-f $path, 'Intel history file created in isolated directory');
    my $info = RRDs::info($path);
    ok(!RRDs::error(), 'RRD schema valid');
    for my $field (qw(freq_req freq_act rc6 power_gpu power_pkg render_busy blitter_busy video_busy videnh_busy)) {
        ok(exists $info->{"ds[$field].type"}, "history field $field exists");
    }
    is($updates[0][-1], 'N:1200.5:1150.25:87.5:3.25:11.5:12.5:0:45:5', 'history values follow the schema order');
    is($updates[1][-1], 'N:U:U:U:U:U:U:U:U:U', 'missing samples become unknown rather than zero');
    update_intel_gpu_rrd('inteltest', $stats);
    ok(!RRDs::error(), 'real RRD update succeeds');
    is(RRDs::info($path)->{'ds[render_busy].last_ds'}, 12.5, 'real RRD stores the render engine load');
}

# ---- API merge -------------------------------------------------------------
{
    my $file = "$dir/stats-card0.json";
    write_file($file, encode_json({ card0 => { name => 'Intel Test', stats => $stats } }));
    my $merged = PVE::API2::PVEMods_SensorInfo::_merge_graphics_files([$file]);
    is($merged->{Graphics}{Intel}{card0}{card}, 'card0', 'API merges Intel into its own vendor group');
    is($merged->{Graphics}{Intel}{card0}{stats}{engines}{Video}{busy}, 45, 'Intel stats survive the merge');
    ok(!keys %{$merged->{Graphics}{NVIDIA}}, 'Intel data never becomes NVIDIA data');
    ok(!keys %{$merged->{Graphics}{AMD}}, 'Intel data never becomes AMD data');
    is(${$merged->{enable_fans}}, 0, 'Intel has no fan data so fans stay disabled');
}

# ---- Collector loop (debug output fixture) ---------------------------------
{
    my $device = { card => 'card0', name => 'Intel Test', path => 'pci:vendor=8086,device=1234,card=0',
        drm_path => '/dev/dri/card0', history_id => 'pci000000020' };
    my $work = tempdir(CLEANUP => 1);
    write_file("$work/output.txt", "[\n$obj1,\n" . encode_json($sample) . ",\n");

    local $PVE::PVEMods::Collector::Intel::pve_mods_working_dir = $work;
    local $config{debug}{intel_mode} = 1;
    local $config{debug}{intel_output_file} = "$work/output.txt";
    local $config{gpu}{gpu_history} = 0;
    local $config{intervals}{data_pull} = 1;
    my $file = "$work/stats-card0.json";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        collector_for_intel_device($device);
        POSIX::_exit(1);
    }
    for (1..100) {
        last if -s $file;
        sleep 0.05;
    }
    ok(-s $file, 'collector publishes a state file');
    if (-s $file) {
        open my $fh, '<', $file or die $!;
        local $/;
        my $data = decode_json(<$fh>);
        close $fh;
        is($data->{card0}{name}, 'Intel Test', 'state file keeps the device name');
        is($data->{card0}{history_id}, 'pci000000020', 'state file keeps the history id');
        is($data->{card0}{stats}{engines}{Video}{busy}, 45, 'state file carries parsed stats');
    }
    kill 'TERM', $pid;
    waitpid($pid, 0);
    is($? >> 8, 0, 'collector handles SIGTERM cleanly');
}
done_testing();
