package PVE::PVEMod::ProcessManager;

use strict;
use warnings;
use Exporter 'import';

use POSIX qw(WNOHANG setsid);
use File::Path qw(remove_tree);

use PVE::PVEMod::Config qw(
    %config $process_type
    $pve_mod_working_dir $state_file
    $pve_mod_worker_lock $startup_lock
);
use PVE::PVEMod::Utils qw(
    debug is_process_alive get_process_ppid read_lock_pid
    acquire_exclusive_lock ensure_pve_mod_directory_exists
    check_executable startup_message
);

use PVE::PVEMod::Collector::Intel   qw(get_intel_gpu_devices  collector_for_intel_device);
use PVE::PVEMod::Collector::Nvidia  qw(get_nvidia_gpu_devices  collector_for_nvidia_devices);
use PVE::PVEMod::Collector::Amd     qw(get_amd_gpu_devices    collector_for_amd_device);
use PVE::PVEMod::Collector::LmSensors qw(collector_for_temperature_sensors);
use PVE::PVEMod::Collector::Ups     qw(collector_for_ups);

our @EXPORT_OK = qw(
    pve_mod_starter
    notify_pve_mod_worker
);

# Collector registry — only populated inside the worker process.
# Each forked child has its own copy; the parent never accesses this after forking.
my %collectors = ();

# ============================================================================
# Public API (called from SensorInfo)
# ============================================================================

# Ensures the worker is running.  Starts it if necessary (double-checked locking).
sub pve_mod_starter {
    debug(__LINE__, "Checking if pve_mod_worker is already running");
    if (_worker_lock_file_exists()) {
        debug(__LINE__, "pve_mod_worker process already running, system is already started");
        return "pve_mod_worker process already running, system is already started";
    }
    debug(__LINE__, "PVE mod worker is not running. PVE Mod will be started.");

    startup_message();
    ensure_pve_mod_directory_exists();

    debug(__LINE__, "Trying to acquire startup lock: $startup_lock");
    my $startup_fh = acquire_exclusive_lock($startup_lock, 'startup lock');
    return unless $startup_fh;

    # Second check after acquiring lock
    if (_worker_lock_file_exists()) {
        debug(__LINE__, "Worker started by another process while we waited for lock");
        close($startup_fh);
        unlink($startup_lock);
        return "already running";
    }

    print $startup_fh "$$\n";
    $startup_fh->flush();
    debug(__LINE__, "Wrote PID $$ to startup lock");

    _pve_mod_worker();

    unlink($startup_lock);
    debug(__LINE__, "Released startup lock");
    debug(__LINE__, "pve_mod_worker started successfully, returning");
}

# Sends SIGUSR1 to the worker to reset the inactivity timer.
sub notify_pve_mod_worker {
    debug(__LINE__, "notify_pve_mod_worker called");
    unless (-f $pve_mod_worker_lock) {
        debug(__LINE__, "pve_mod_worker lock file does not exist");
        return;
    }

    debug(__LINE__, "pve_mod_worker lock file exists, reading PID");
    if (open my $fh, '<', $pve_mod_worker_lock) {
        my $pid = <$fh>;
        close $fh;
        chomp $pid if defined $pid;
        if (defined $pid && $pid =~ /^(\d+)$/) {
            my $clean_pid = $1;

            if (is_process_alive($clean_pid)) {
                debug(__LINE__, "Sending USR1 signal to pve_mod_worker PID $clean_pid");
                my $result = kill('USR1', $clean_pid);
                debug(__LINE__, "Signal result: $result");
            } else {
                debug(__LINE__,
                    "pve_mod_worker process $clean_pid is not alive, removing stale lock");
                unlink($pve_mod_worker_lock);
            }
        } else {
            debug(__LINE__,
                "pve_mod_worker lock is stale (PID: " . ($pid // 'undefined') . "), removing");
            unlink($pve_mod_worker_lock);
        }
    } else {
        debug(__LINE__, "Failed to open pve_mod_worker lock file: $!");
    }
}

# ============================================================================
# Worker process management
# ============================================================================

sub _worker_lock_file_exists {
    return 0 unless -f $pve_mod_worker_lock;

    my $pid = read_lock_pid($pve_mod_worker_lock);
    if (!defined $pid || $pid !~ /^(\d+)$/) {
        debug(__LINE__, "Worker lock is invalid (PID: " . ($pid // 'undefined') . "), removing");
        unlink($pve_mod_worker_lock);
        return 0;
    }
    my $worker_pid = $1;

    if (is_process_alive($worker_pid)) {
        return 1;
    }

    debug(__LINE__, "Stale or zombie worker lock found for PID $worker_pid, reaping if needed");
    my $reaped_pid = waitpid($worker_pid, WNOHANG);
    if ($reaped_pid == $worker_pid) {
        debug(__LINE__, "Reaped stale worker PID $worker_pid");
    } elsif ($reaped_pid == -1 && $!{ECHILD}) {
        # Expected once the worker is double-forked: we're not its parent, init is.
        debug(__LINE__, "PID $worker_pid is not a child of this process; treating lock as stale");
    } else {
        debug(__LINE__, "waitpid on PID $worker_pid returned $reaped_pid: $!");
    }

    unlink($pve_mod_worker_lock);
    return 0;
}

# Double-forks so the worker is reparented to init (PID 1) instead of the
# caller; init reaps it on exit, so it never lingers as a <defunct> zombie.
sub _pve_mod_worker {
    debug(__LINE__, "_pve_mod_worker called");

    my $pve_mod_worker_fh =
        acquire_exclusive_lock($pve_mod_worker_lock, 'pve_mod_worker lock');
    return unless $pve_mod_worker_fh;
    print $pve_mod_worker_fh "$$\n";
    close($pve_mod_worker_fh);

    debug(__LINE__, "Forking intermediate process for pve_mod_worker");
    my $intermediate_pid = fork();

    unless (defined $intermediate_pid) {
        debug(__LINE__, "Failed to fork intermediate pve_mod_worker process: $!");
        unlink($pve_mod_worker_lock);
        return;
    }

    if ($intermediate_pid == 0) {
        # Intermediate child: detach into its own session, fork the real
        # worker, then exit immediately so the worker is reparented to init.
        setsid();

        my $worker_pid = fork();
        unless (defined $worker_pid) {
            debug(__LINE__, "Failed to fork pve_mod_worker process: $!");
            unlink($pve_mod_worker_lock);
            POSIX::_exit(1);
        }

        if ($worker_pid == 0) {
            # Grandchild — the actual worker
            $0 = "pve_mod_worker_controller";
            if (open my $fh, '>', $pve_mod_worker_lock) {
                print $fh "$$\n";
                close $fh;
                debug(__LINE__, "Wrote pve_mod_worker PID to lock file: $pve_mod_worker_lock");
            } else {
                debug(__LINE__, "Failed to write pve_mod_worker lock file: $!");
            }
            debug(__LINE__, "Worker process forked, calling _pve_mod_keep_alive");
            _pve_mod_keep_alive();
            exit(0);
        }

        debug(__LINE__, "Intermediate process exiting, worker PID $worker_pid reparented to init");
        # _exit (not exit) so we skip END blocks/global destruction — this
        # process only ever existed to perform the double fork.
        POSIX::_exit(0);
    }

    # Parent — reap the short-lived intermediate process immediately, so it
    # never has a chance to become a zombie under us either.
    waitpid($intermediate_pid, 0);
    my $status = $? >> 8;
    if ($status == 0) {
        debug(__LINE__, "pve_mod_worker process started successfully");
    } else {
        debug(__LINE__, "Intermediate pve_mod_worker process exited with status $status");
    }
}

# ============================================================================
# Worker keep-alive loop
# ============================================================================

sub _pve_mod_keep_alive {
    $process_type = 'worker';
    debug(__LINE__, "pve_mod_worker process started with PID $$");

    my $last_activity = time();

    $SIG{USR1} = sub {
        $last_activity = time();
        debug(__LINE__, "Activity ping received");
    };

    $SIG{CHLD} = sub {
        while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            my $exit_status = $? >> 8;
            debug(__LINE__, "Child process $pid exited with status $exit_status");

            foreach my $name (keys %collectors) {
                if ($collectors{$name} == $pid) {
                    debug(__LINE__,
                        "Collector '$name' (PID $pid) exited, removing from registry");
                    delete $collectors{$name};
                    last;
                }
            }
        }
    };

    $SIG{TERM} = sub {
        debug(__LINE__, "pve_mod_worker received SIGTERM, shutting down");
        _stop_child_collectors();
        unlink($pve_mod_worker_lock) if -f $pve_mod_worker_lock;
        exit(0);
    };
    $SIG{INT} = sub {
        debug(__LINE__, "pve_mod_worker received SIGINT, shutting down");
        _stop_child_collectors();
        unlink($pve_mod_worker_lock) if -f $pve_mod_worker_lock;
        exit(0);
    };

    _reap_orphaned_collectors();

    debug(__LINE__, "Worker starting all collectors");
    _initialise_sensors_collector();
    _initialise_graphics_collectors();
    _initialise_ups_collector();
    debug(__LINE__, "All collectors started by worker");

    debug(__LINE__,
        "Entering pve_mod_worker loop, timeout=$config{intervals}{collector_timeout}s");

    while (1) {
        debug(__LINE__, "pve_mod_worker loop start: checking activity");

        my $idle_time = time() - $last_activity;
        debug(__LINE__,
            "pve_mod_worker loop: idle_time=${idle_time}s, "
            . "timeout=$config{intervals}{collector_timeout}s");

        if ($idle_time > $config{intervals}{collector_timeout}) {
            debug(__LINE__, "Timeout reached, stopping collectors");
            _stop_child_collectors();
            debug(__LINE__, "Collectors stopped, exiting pve_mod_worker");
            unlink($pve_mod_worker_lock) if -f $pve_mod_worker_lock;
            exit(0);
        }
        sleep(1);
    }

    debug(__LINE__, "pve_mod_worker loop exited unexpectedly!");
}

# ============================================================================
# Collector startup helpers (called from worker loop)
# ============================================================================

sub _initialise_sensors_collector {
    return unless $config{lm_sensors}{enabled};
    return unless check_executable('/usr/bin/sensors', 'lm-sensors',
                                   $config{debug}{lm_sensors_mode},
                                   $config{debug}{lm_sensors_output_file});

    debug(__LINE__, "Starting lm-sensors collector");
    _start_collector('sensors', 'sensors',
                     \&collector_for_temperature_sensors,
                     { name => 'sensors' });
}

sub _initialise_ups_collector {
    unless ($config{ups}{enabled} && $config{ups}{device_name}) {
        debug(__LINE__, "UPS collection disabled/invalid in config, skipping");
        return;
    }
    return unless check_executable('/usr/bin/upsc', 'UPS',
                                   $config{debug}{ups_mode},
                                   $config{debug}{ups_output_file});

    debug(__LINE__, "Starting UPS collector: $config{ups}{device_name}");
    _start_collector('ups', 'ups', \&collector_for_ups,
                     { ups_name => $config{ups}{device_name} });
}

sub _initialise_graphics_collectors {
    unless ($config{gpu}{intel_enabled}
            || $config{gpu}{amd_enabled}
            || $config{gpu}{nvidia_enabled}) {
        debug(__LINE__, "No GPU types enabled, skipping collector startup");
        return;
    }

    debug(__LINE__, "Starting graphics collectors");

    my (@all_devices, @all_types, @all_collector_subs);
    my @nvidia_devices;

    # Intel (each GPU has its own collector)
    if ($config{gpu}{intel_enabled} && check_executable('/usr/bin/intel_gpu_top', 'Intel',
                                                        $config{debug}{intel_mode},
                                                        $config{debug}{intel_devices_file})) {
        my @intel_devices = get_intel_gpu_devices();
        for my $device (@intel_devices) {
            push @all_devices,        $device;
            push @all_types,          'intel';
            push @all_collector_subs, \&collector_for_intel_device;
        }
    }

    # AMD (each GPU has its own collector)
    if ($config{gpu}{amd_enabled} && check_executable('/usr/bin/rocm-smi', 'AMD',
                                                      $config{debug}{amd_mode},
                                                      $config{debug}{amd_devices_file})) {
        my @amd_devices = get_amd_gpu_devices();
        for my $device (@amd_devices) {
            push @all_devices,        $device;
            push @all_types,          'amd';
            push @all_collector_subs, \&collector_for_amd_device;
        }
    }

    # NVIDIA (all GPUs collected together in one collector due to nvidia-smi design)
    if ($config{gpu}{nvidia_enabled} && check_executable('/usr/bin/nvidia-smi', 'NVIDIA',
                                                         $config{debug}{nvidia_mode},
                                                         $config{debug}{nvidia_devices_file})) {
        @nvidia_devices = get_nvidia_gpu_devices();
    }

    debug(__LINE__,
        "Detected: "
        . scalar(grep { $_ eq 'intel' } @all_types) . " Intel, "
        . scalar(grep { $_ eq 'amd' }   @all_types) . " AMD, "
        . scalar(@nvidia_devices) . " NVIDIA");

    my $started_count = 0;

    # Start individual collectors for Intel and AMD devices
    for (my $i = 0; $i < @all_devices; $i++) {
        my $device        = $all_devices[$i];
        my $type          = $all_types[$i];
        my $collector_sub = $all_collector_subs[$i];
        my $device_name   = $device->{card} // $device->{name} // "device$i";

        my $pid = _start_collector($device_name, $type, $collector_sub, $device);
        $started_count++ if $pid;
    }

    # NVIDIA — single collector for all GPUs
    if (@nvidia_devices) {
        my $pid = _start_collector('nvidia-all', 'nvidia',
                                   \&collector_for_nvidia_devices,
                                   \@nvidia_devices);
        $started_count++ if $pid;
    }

    debug(__LINE__,
        "Started/verified $started_count graphics collector(s)");
}

# ============================================================================
# Generic collector start/stop
# ============================================================================

sub _start_collector {
    my ($collector_name, $collector_type, $collector_sub, $device) = @_;

    debug(__LINE__, "Starting $collector_type collector: $collector_name");

    if (exists $collectors{$collector_name}) {
        my $pid = $collectors{$collector_name};
        if (kill(0, $pid)) {
            debug(__LINE__,
                "$collector_type collector '$collector_name' already running with PID $pid");
            return $pid;
        } else {
            debug(__LINE__,
                "Collector '$collector_name' PID $pid is stale, removing from registry");
            delete $collectors{$collector_name};
        }
    }

    my $pid = _start_child_collector($collector_name, $collector_sub, $device);

    unless ($pid) {
        debug(__LINE__, "Failed to start $collector_type collector '$collector_name'");
        return undef;
    }

    $collectors{$collector_name} = $pid;
    debug(__LINE__,
        "Registered $collector_type collector '$collector_name' with PID $pid");

    sleep 0.1;
    if (kill(0, $pid)) {
        debug(__LINE__,
            "Verified $collector_type collector '$collector_name' (PID $pid) is alive");
        return $pid;
    } else {
        debug(__LINE__,
            "WARNING - $collector_type collector '$collector_name' (PID $pid) died immediately!");
        delete $collectors{$collector_name};
        return undef;
    }
}

sub _start_child_collector {
    my ($collector_name, $collector_sub, $device) = @_;

    debug(__LINE__, "Starting child collector: $collector_name");

    my $pid = fork();
    unless (defined $pid) {
        debug(__LINE__, "fork failed for $collector_name: $!");
        return undef;
    }

    if ($pid == 0) {
        $process_type = 'collector';
        debug(__LINE__, "In child process for $collector_name");
        $0 = "collector-$collector_name";
        $collector_sub->($device);
        exit(0);
    }

    debug(__LINE__, "Forked child PID $pid for $collector_name");
    return $pid;
}

sub _stop_child_collectors {
    debug(__LINE__, "Stopping all collectors");

    my @pids = values %collectors;

    if (@pids) {
        debug(__LINE__, "Sending SIGTERM to " . scalar(@pids) . " collector process(es)");
        foreach my $pid (@pids) {
            if (kill(0, $pid)) {
                kill('TERM', $pid);
                debug(__LINE__, "Sent SIGTERM to collector PID $pid");
            }
        }

        my $timeout = 2;
        my $start   = time();
        while (time() - $start < $timeout) {
            my $any_alive = 0;
            foreach my $pid (@pids) {
                if (kill(0, $pid)) { $any_alive = 1; last; }
            }
            last unless $any_alive;
            select(undef, undef, undef, 0.1);
        }

        foreach my $pid (@pids) {
            if (kill(0, $pid)) {
                debug(__LINE__, "Force killing collector process $pid");
                kill('KILL', $pid);
            }
        }
    }

    %collectors = ();
    debug(__LINE__, "Cleared collector registry");

    if (-f $state_file) {
        unlink $state_file or debug(__LINE__, "Failed to remove $state_file: $!");
    }

    if (-d $pve_mod_working_dir) {
        remove_tree($pve_mod_working_dir, { error => \my $err });
        debug(__LINE__, "Cleanup errors: @$err") if @$err;
    }

    debug(__LINE__, "Cleanup complete");
}

# Finds and terminates collector processes left behind by a previous worker
# that never got to run _stop_child_collectors() (e.g. killed with SIGKILL).
# Only targets processes reparented to init, never a running worker's own.
sub _reap_orphaned_collectors {
    debug(__LINE__, "Scanning for orphaned collector processes from a previous worker");

    my $dh;
    unless (opendir($dh, '/proc')) {
        debug(__LINE__, "Failed to open /proc: $!");
        return;
    }

    my @orphans;
    while (my $entry = readdir($dh)) {
        next unless $entry =~ /^(\d+)$/;
        my $pid = $1;
        next if $pid == $$;

        next unless open(my $fh, '<', "/proc/$pid/cmdline");
        my $cmdline = <$fh>;
        close($fh);
        next unless defined $cmdline;

        my ($name) = split /\0/, $cmdline;
        next unless defined $name && $name =~ /^collector-/;

        my $ppid = get_process_ppid($pid);
        next unless defined $ppid && $ppid == 1;

        push @orphans, $pid;
    }
    closedir($dh);

    unless (@orphans) {
        debug(__LINE__, "No orphaned collectors found");
        return;
    }

    debug(__LINE__, "Found " . scalar(@orphans) . " orphaned collector(s), terminating");
    foreach my $pid (@orphans) {
        kill('TERM', $pid);
        debug(__LINE__, "Sent SIGTERM to orphaned collector PID $pid");
    }

    # Orphans are already zombies as soon as init reaps them, and kill(0,...)
    # keeps reporting a zombie's PID as present - use is_process_alive() so we
    # don't spin the full timeout (or send a pointless KILL) on a dead PID.
    my $timeout = 2;
    my $start   = time();
    while (time() - $start < $timeout) {
        my $any_alive = 0;
        foreach my $pid (@orphans) {
            if (is_process_alive($pid)) { $any_alive = 1; last; }
        }
        last unless $any_alive;
        select(undef, undef, undef, 0.1);
    }

    foreach my $pid (@orphans) {
        if (is_process_alive($pid)) {
            debug(__LINE__, "Force killing orphaned collector process $pid");
            kill('KILL', $pid);
        }
    }

    debug(__LINE__, "Orphan cleanup complete");
}

# ============================================================================
# END block — only the worker process performs cleanup
# ============================================================================

END {
    if ($process_type eq 'worker') {
        debug(__LINE__, "PVE Mod Worker END block: cleaning up");
        _stop_child_collectors();
    } elsif ($process_type eq 'collector') {
        debug(__LINE__, "Collector ($0) END block: no cleanup needed");
    } else {
        debug(__LINE__, "Main process END block: no cleanup needed");
    }
}

1;
