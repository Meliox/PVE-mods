use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../src/modules/node_info/files";
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/conf.d");

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh or die "$path: $!";
}

sub read_source {
    open my $fh, '<', "$_[0]" or die $!;
    local $/;
    my $source = <$fh>;
    $source =~ s/^\xEF\xBB\xBF//;
    return $source;
}

# Exercise the real startup loader against an isolated /etc equivalent.
my $source = read_source("$root/Config.pm");
$source =~ s{'/etc/pve-mods/pve-mods.conf'}{'$dir/main.conf'};
$source =~ s{'/etc/pve-mods/conf.d'}{'$dir/conf.d'};
my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval $source;
    die $@ if $@;
}
is_deeply($PVE::PVEMods::Config::config{intervals},
    { data_pull => 1, collector_timeout => 10 }, 'missing files preserve defaults');

sub load_ini {
    write_file("$dir/input.conf", $_[0]);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    PVE::PVEMods::Config::_load_ini_file("$dir/input.conf");
}

load_ini("[gpu]\nintel_enabled=1\n[intervals]\ndata_pull = 5 # seconds\ncollector_timeout=120\nunknown=7\n[debug]\nmod_debug=1\n[ups]\ndevice_name=test\n[lm_sensors]\nenabled=1\n[system_info]\ntemp_unit=F\n");
is_deeply($PVE::PVEMods::Config::config{intervals},
    { data_pull => 5, collector_timeout => 120 }, 'known intervals loaded');
is($PVE::PVEMods::Config::config{gpu}{intel_enabled}, 1, 'GPU config preserved');
is($PVE::PVEMods::Config::config{debug}{mod_debug}, 1, 'debug config preserved');
is($PVE::PVEMods::Config::config{ups}{device_name}, 'test', 'UPS config preserved');
is($PVE::PVEMods::Config::config{lm_sensors}{enabled}, 1, 'sensor config preserved');
is($PVE::PVEMods::Config::config{system_info}{temp_unit}, 'F', 'system config preserved');
is(scalar @warnings, 0, 'valid values and unknown keys do not warn');

for my $v (['1', 1], ['120', 120], ['007', 7], ['2147483647', 2147483647], ['5 # seconds', 5], [' 5 ', 5]) {
    my ($raw, $norm) = @$v;
    @warnings = ();
    load_ini("[intervals]\ndata_pull=$raw\ncollector_timeout=$raw\n");
    is_deeply($PVE::PVEMods::Config::config{intervals},
        { data_pull => $norm, collector_timeout => $norm }, "accept '$raw' as $norm");
    is(scalar @warnings, 0, 'no warning for valid value');
}
load_ini("[intervals]\ndata_pull=5\ncollector_timeout=120\n");

for my $bad ('', '0', '-1', '1.5', 'abc', '1e2', '+5', '5 seconds',
             '2147483648', '999999999999999999999999999999') {
    @warnings = ();
    load_ini("[intervals]\ndata_pull=$bad\ncollector_timeout=$bad\n");
    is_deeply($PVE::PVEMods::Config::config{intervals},
        { data_pull => 5, collector_timeout => 120 }, "reject '$bad' and retain values");
    is(scalar @warnings, 2, 'one warning per invalid option');
    like($warnings[0], qr/input\.conf line 2: invalid \[intervals\] data_pull/,
        'warning identifies file, line and option');
}
load_ini("[intervals]\ndata_pull\ncollector_timeout=1\n");
is($PVE::PVEMods::Config::config{intervals}{data_pull}, 5, 'missing assignment ignored');
is($PVE::PVEMods::Config::config{intervals}{collector_timeout}, 1, 'minimum accepted');
load_ini("[intervals]\ndata_pull=2147483647\n");
is($PVE::PVEMods::Config::config{intervals}{data_pull}, 2147483647, 'maximum accepted');

# The configure wizard (bash) is exercised by running its real functions against
# a temporary config directory; prompts are answered from stdin.
my $wizard = "$root/../node_info.configure.sh";
my $wdir = "$dir/wizard";
my $wconf = "$wdir/node_info.conf";
make_path($wdir);

sub wizard {    # ($bash_body, $stdin) -> (last stdout line, stderr)
    my ($body, $input) = @_;
    write_file("$dir/in.txt", $input // '');
    write_file("$dir/run.sh", <<"SH" . $body);
CONFD_DIR='$wdir'
warn() { echo "\$*" >&2; }
info() { :; }
section() { :; }
source '$wizard'
show() { echo "\$DATA_PULL_INTERVAL \$COLLECTOR_TIMEOUT"; }
SH
    my @out = `bash $dir/run.sh < $dir/in.txt 2> $dir/err.txt`;
    open my $fh, '<', "$dir/err.txt" or die $!;
    my $err = do { local $/; <$fh> };
    my $last = @out ? $out[-1] : '';
    chomp $last;
    return ($last, $err // '');
}
my $reload = 'node_info_defaults; node_info_load_conf; ';

is((wizard('node_info_defaults; show'))[0], '1 10', 'wizard defaults');
is((wizard('node_info_defaults; _configure_intervals; show', "\n\n"))[0], '1 10',
    'Enter accepts the defaults');
is((wizard('node_info_defaults; _configure_intervals; show', "0\nabc\n2147483648\n7\n-1\n300\n"))[0],
    '7 300', 'prompts reject invalid answers');

# configure -> save -> reload
is((wizard('node_info_defaults; _configure_intervals; node_info_write_conf; ' . $reload . 'show',
    "9\n450\n"))[0], '9 450', 'configured values survive save and reload');
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    @warnings = ();
    PVE::PVEMods::Config::_load_ini_file($wconf);
    is_deeply($PVE::PVEMods::Config::config{intervals},
        { data_pull => 9, collector_timeout => 450 }, 'Config.pm loads the wizard-written file');
    is(scalar @warnings, 0, 'no warnings for the wizard-written file');
}
is((wizard($reload . 'echo "$ENABLE_UPS $DATA_PULL_INTERVAL $COLLECTOR_TIMEOUT"', ''))[0], '0 9 450',
    'saved values reload');
is((wizard($reload . 'ENABLE_UPS=1; node_info_write_conf; ' . $reload
    . 'echo "$ENABLE_UPS $DATA_PULL_INTERVAL $COLLECTOR_TIMEOUT"'))[0], '1 9 450',
    'unrelated change keeps the saved values');
my $saved = read_source($wconf);
wizard($reload . 'node_info_write_conf');
is(read_source($wconf), $saved, 'repeated save is stable');

load_ini("[intervals]\ndata_pull=5\ncollector_timeout=120\n");

write_file("$dir/main.conf", "[intervals]\ndata_pull=2\ncollector_timeout=30\n");
write_file("$dir/conf.d/10-first.conf", "[intervals]\ndata_pull=3\n");
write_file("$dir/conf.d/90-intervals.conf", "[intervals]\ndata_pull=5\ncollector_timeout=120\n");
write_file("$dir/conf.d/99-invalid.conf", "[intervals]\ncollector_timeout=0\n");
write_file("$dir/conf.d/99-ignored.txt", "[intervals]\ndata_pull=9\n");
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval $source;
    die $@ if $@;
}
is_deeply($PVE::PVEMods::Config::config{intervals},
    { data_pull => 5, collector_timeout => 120 }, 'startup merges main then sorted .conf files');

# Run the unchanged worker loop with a deterministic clock and stub collectors.
# No real processes, signals, system tools or /run files are touched.
{
    package WorkerTest;
    our ($now, $ping_at, $started, $stopped);
    sub time { return $now }
    sub sleep {
        $now++;
        $SIG{USR1}->() if defined $ping_at && $now == $ping_at;
    }
    sub exit { die "worker exited\n" }
}
my $worker = read_source("$root/ProcessManager.pm");
$worker =~ s/use PVE::PVEMods::[^;]+;//gs;
$worker =~ s/package PVE::PVEMods::ProcessManager;/package PVE::PVEMods::ProcessManager;
    use subs qw(time sleep exit);
    our (%config, \$process_type, \$pve_mods_working_dir, \$state_file,
         \$sensors_state_file, \$ups_state_file, \$storage_health_state_file,
         \$pve_mods_worker_lock, \$startup_lock);
/;
{
    no warnings 'once';
    *PVE::PVEMods::ProcessManager::time = \&WorkerTest::time;
    *PVE::PVEMods::ProcessManager::sleep = \&WorkerTest::sleep;
    *PVE::PVEMods::ProcessManager::exit = \&WorkerTest::exit;
    *PVE::PVEMods::ProcessManager::config = \%PVE::PVEMods::Config::config;
    $PVE::PVEMods::ProcessManager::process_type = 'main';
    $PVE::PVEMods::ProcessManager::pve_mods_worker_lock = "$dir/worker.lock";
}
eval $worker;
die $@ if $@;
{
    no warnings qw(redefine once);
    *PVE::PVEMods::ProcessManager::debug = sub {};
    *PVE::PVEMods::ProcessManager::_reap_orphaned_collectors = sub {};
    *PVE::PVEMods::ProcessManager::_initialise_sensors_collector = sub { $WorkerTest::started++ };
    *PVE::PVEMods::ProcessManager::_initialise_graphics_collectors = sub {};
    *PVE::PVEMods::ProcessManager::_initialise_ups_collector = sub {};
    *PVE::PVEMods::ProcessManager::_initialise_storage_health_collector = sub {};
    *PVE::PVEMods::ProcessManager::_stop_child_collectors = sub { $WorkerTest::stopped++ };
}
for my $case ([10, undef, 11], [120, undef, 121], [120, 60, 181]) {
    my ($timeout, $ping, $expected) = @$case;
    $PVE::PVEMods::Config::config{intervals}{collector_timeout} = $timeout;
    ($WorkerTest::now, $WorkerTest::ping_at, $WorkerTest::started, $WorkerTest::stopped)
        = (0, $ping, 0, 0);
    write_file("$dir/worker.lock", "test\n");
    {
        local %SIG = %SIG;
        no warnings 'redefine';
        local *POSIX::_exit = sub { die "worker exited\n" };
        eval { PVE::PVEMods::ProcessManager::_pve_mods_keep_alive() };
    }
    is($@, "worker exited\n", 'worker exits normally on inactivity');
    $PVE::PVEMods::ProcessManager::process_type = 'main';
    is($WorkerTest::now, $expected, "timeout $timeout respects activity reset");
    is($WorkerTest::started, 1, 'sensor collector started once');
    is($WorkerTest::stopped, 1, 'collectors stopped on timeout');
    ok(!-e "$dir/worker.lock", 'worker lock removed');
}

done_testing();
