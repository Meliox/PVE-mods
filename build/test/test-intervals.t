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

sub read_vectors {
    open my $fh, '<', "$FindBin::Bin/fixtures/interval-values.txt" or die $!;
    my (@accept, @reject);
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^#/ || $l eq '';
        my ($kind, $raw, $norm) = split /\|/, $l, 3;
        $raw = '' unless defined $raw;
        push @{ $kind eq 'accept' ? \@accept : \@reject }, [$raw, $norm];
    }
    return (\@accept, \@reject);
}
my ($accept, $reject) = read_vectors();

for my $v (@$accept) {
    my ($raw, $norm) = @$v;
    @warnings = ();
    load_ini("[intervals]\ndata_pull=$raw\ncollector_timeout=$raw\n");
    is_deeply($PVE::PVEMods::Config::config{intervals},
        { data_pull => $norm, collector_timeout => $norm }, "accept '$raw' as $norm");
    is(scalar @warnings, 0, 'no warning for valid value');
}
load_ini("[intervals]\ndata_pull=5\ncollector_timeout=120\n");

for my $bad (map { $_->[0] } @$reject) {
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

my $wizard_conf = $ENV{INTERVALS_WIZARD_CONF};
if (defined $wizard_conf) {
    @warnings = ();
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    PVE::PVEMods::Config::_load_ini_file($wizard_conf);
    is_deeply($PVE::PVEMods::Config::config{intervals},
        { data_pull => 7, collector_timeout => 300 },
        'wizard-written node_info.conf loads in Config.pm');
    is(scalar @warnings, 0, 'wizard-written file loads without warnings');
    load_ini("[intervals]\ndata_pull=5\ncollector_timeout=120\n");
}

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
