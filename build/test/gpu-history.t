use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(decode_json encode_json);
use POSIX ();
use Socket qw(SOCK_STREAM);
use lib "$ENV{AMD_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Store qw(update_gpu_rrd flush_gpu_rrds gpu_rrd_path read_gpu_rrd_data);
use PVE::PVEMods::Config qw(%config);
use RRDs;

my $dir = tempdir(CLEANUP => 1);
local $PVE::PVEMods::Store::RRD_BASE = $dir;
local $config{gpu}{gpu_history} = 0;
local $config{intervals}{gpu_history_flush} = 1;  # write every sample unless a test buffers
my $test_now = time() - 100;
no warnings 'redefine';
local *PVE::PVEMods::Store::_now = sub { $test_now++ };
# AMD supplies a fixture for the shared Store code; schemas are tested per vendor.
my $stats = { utilization => { gpu => 0 }, memory => { used => 64, total => 4096 },
    gtt => { used => 128, total => 8192 }, frequency => { actual => 800 },
    power => { draw => 10.041 }, temperature => { gpu => 40 }, fan => { speed => 0, unit => 'RPM' } };
update_gpu_rrd(amd => 'testgpu', $stats);
ok(!-e gpu_rrd_path('testgpu'), 'disabled history does not create files');
$config{gpu}{gpu_history} = 1;
eval { update_gpu_rrd(hal9000 => 'testgpu', $stats) };
like($@, qr/unknown GPU vendor/, 'unknown vendors are rejected');
update_gpu_rrd(amd => 'testgpu', $stats);
ok(!RRDs::error(), 'real RRD update succeeds');
{
    local $config{intervals}{gpu_history_flush} = 60;
    my @buffered;
    no warnings 'redefine';
    local *RRDs::update = sub { push @buffered, [@_] };
    update_gpu_rrd(amd => 'amdbuf', $stats) for 1 .. 3;
    is(scalar @buffered, 0, 'samples are buffered in memory, not written each second');
    flush_gpu_rrds();
    is(scalar @buffered, 1, 'the shutdown flush writes the buffer in a single call');
    is(scalar @{ $buffered[0] } - 1, 3, 'that call carries every buffered sample');
    my ($ts1) = $buffered[0][1] =~ /^(\d+):/;
    my ($ts3) = $buffered[0][3] =~ /^(\d+):/;
    cmp_ok($ts3, '>', $ts1, 'buffered samples keep strictly increasing timestamps');
}
{
    local $config{intervals}{gpu_history_flush} = 60;
    my $now = time() - 120;
    local *PVE::PVEMods::Store::_now = sub { $now };
    my @buffered;
    local *RRDs::update = sub { push @buffered, [@_] };
    update_gpu_rrd(amd => 'amdinterval', $stats);
    $now += 58;
    update_gpu_rrd(amd => 'amdinterval', $stats);
    is(scalar @buffered, 0, 'buffer is not written before the configured interval');
    $now++;
    update_gpu_rrd(amd => 'amdinterval', $stats);
    is(scalar @buffered, 1, 'buffer is written when the configured interval is reached');
    is(scalar @{ $buffered[0] } - 1, 3, 'scheduled write includes every buffered sample');
}
{
    local $config{intervals}{gpu_history_flush} = 60;
    my $now = time() - 20;
    local *PVE::PVEMods::Store::_now = sub { $now };
    update_gpu_rrd(amd => 'amdduplicate', $stats);
    update_gpu_rrd(amd => 'amdduplicate', { utilization => { gpu => 42 } });
    flush_gpu_rrds();
    my $duplicate_path = gpu_rrd_path('amdduplicate');
    is(RRDs::last($duplicate_path), $now, 'same-second samples never move timestamps into the future');
    is(RRDs::info($duplicate_path)->{'ds[gpu_util].last_ds'}, 42,
        'the latest same-second sample is retained');
    update_gpu_rrd(amd => 'amdduplicate', $stats);
    flush_gpu_rrds();
    is(RRDs::last($duplicate_path), $now, 'a sample for an already-written second is skipped');
}
{
    local $config{intervals}{gpu_history_flush} = 1;
    my $now = time() - 10;
    local *PVE::PVEMods::Store::_now = sub { $now };
    my $existing_path = gpu_rrd_path('amdexisting');
    RRDs::create($existing_path, '--start', $now - 2, '--step', '1',
        'DS:gpu_util:GAUGE:120:0:100', 'RRA:AVERAGE:0.5:60:1440');
    RRDs::update($existing_path, "$now:12");
    update_gpu_rrd(amd => 'amdexisting', $stats);
    is(RRDs::last($existing_path), $now, 'an existing RRD is not updated twice in the same second');
    is(RRDs::info($existing_path)->{'ds[gpu_util].last_ds'}, 12, 'existing sample is preserved after restart');
}
{
    my $now = 60 * int(time() / 60);
    RRDs::create(gpu_rrd_path('amdread'), '--start', $now - 600, '--step', '1',
        'DS:gpu_util:GAUGE:120:0:100', 'RRA:AVERAGE:0.5:60:1440');
    RRDs::update(gpu_rrd_path('amdread'), map { ($now - 300 + $_) . ':42' } 0 .. 120);
    my @rows = grep { defined $_->{gpu_util} } @{ read_gpu_rrd_data('amdread', 'hour') };
    is($rows[0]{gpu_util}, 42, 'history reader returns stored samples directly from the file');
    eval { read_gpu_rrd_data('../amdread', 'hour') };
    like($@, qr/invalid card name/, 'history reader rejects path components');
}
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    no warnings 'redefine';
    local *RRDs::error = sub { 'Permission denied' };
    update_gpu_rrd(amd => 'testgpu', $stats) for 1 .. 3;
    is(scalar(@warnings), 1, 'a persistent RRD failure is logged once, not every sample');
}
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    update_gpu_rrd(amd => 'testgpu', $stats);
    is(scalar(@warnings), 1, 'recovery after a failure is logged');
    like($warnings[0], qr/resumed/, 'the recovery message says recording resumed');
}
{
    my $permission_dir = tempdir(CLEANUP => 1);
    my $socket_path = "$permission_dir/rrdcached.sock";
    my $socket = IO::Socket::UNIX->new(
        Type => SOCK_STREAM, Local => $socket_path, Listen => 1,
    ) or die "socket: $!";
    chmod 0000, $socket_path or die "chmod socket: $!";
    my ($uid, $gid) = (getpwnam('nobody'))[2, 3];
    SKIP: {
        skip 'an unprivileged account is required for the socket permission test', 5
            if $> == 0 && !defined $uid;
        chown $uid, $gid, $permission_dir or die "chown: $!" if $> == 0;
        pipe(my $reader, my $writer) or die "pipe: $!";
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            close $reader;
            if ($> == 0) {
                POSIX::setgid($gid) == 0 && POSIX::setuid($uid) == 0
                    or die "cannot drop privileges: $!";
            }
            local $PVE::PVEMods::Store::RRD_BASE = $permission_dir;
            local $config{intervals}{gpu_history_flush} = 1;
            local *PVE::PVEMods::Store::_now = sub { time() };
            local $ENV{RRDCACHED_ADDRESS} = "unix:$socket_path";
            my @warnings;
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            update_gpu_rrd(amd => 'amdpermission', $stats);
            my $history = gpu_rrd_path('amdpermission');
            $config{intervals}{gpu_history_flush} = 60;
            update_gpu_rrd(amd => 'amdbufferedpermission', $stats);
            flush_gpu_rrds();
            my ($info, $direct_error, $buffered_info, $buffered_error);
            {
                local $ENV{RRDCACHED_ADDRESS};
                delete $ENV{RRDCACHED_ADDRESS};
                $info = RRDs::info($history);
                $direct_error = RRDs::error();
                $buffered_info = RRDs::info(gpu_rrd_path('amdbufferedpermission'));
                $buffered_error = RRDs::error();
            }
            RRDs::update($history, '--daemon', "unix:$socket_path", 'N:0:0:0:0:0:0:0:0:0:0');
            my $daemon_error = RRDs::error();
            my $rows = eval { read_gpu_rrd_data('amdpermission', 'hour') };
            my $read_error = $@;
            print {$writer} encode_json({
                daemon_error => $daemon_error,
                direct_ok => !$direct_error && $info->{'ds[gpu_util].last_ds'} == 0 && !@warnings,
                buffered_ok => !$buffered_error && $buffered_info->{'ds[gpu_util].last_ds'} == 0,
                read_ok => !$read_error && ref($rows) eq 'ARRAY',
                environment_ok => $ENV{RRDCACHED_ADDRESS} eq "unix:$socket_path",
            });
            close $writer;
            POSIX::_exit(0);
        }
        close $writer;
        my $result = do { local $/; <$reader> };
        close $reader;
        waitpid($pid, 0);
        die "socket permission test child failed: $?" if $? != 0;
        my $outcome = decode_json($result);
        like($outcome->{daemon_error}, qr/Permission denied/i, 'inaccessible rrdcached socket reproduces the reported error');
        ok($outcome->{direct_ok}, 'unprivileged collector writes GPU history without the socket');
        ok($outcome->{buffered_ok}, 'shutdown flush writes GPU history without the socket');
        ok($outcome->{read_ok}, 'unprivileged API reads GPU history without the socket');
        ok($outcome->{environment_ok}, 'RRD operations preserve the caller environment');
    }
}
done_testing();
