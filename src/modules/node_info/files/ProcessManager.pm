package PVE::PVEMods::ProcessManager;

use strict;
use warnings;
use Exporter 'import';

use POSIX qw(WNOHANG setsid);
use File::Path qw(remove_tree);

use PVE::PVEMods::Config qw(
    %config $process_type
    $pve_mods_working_dir $state_file
    $sensors_state_file $ups_state_file
    $pve_mods_worker_lock $startup_lock
);
use PVE::PVEMods::Utils qw(
    debug is_process_alive get_process_ppid read_lock_pid
    acquire_exclusive_lock ensure_pve_mods_directory_exists
    check_executable startup_message
);

use PVE::PVEMods::Collector::Intel   qw(get_intel_gpu_devices  collector_for_intel_device);
use PVE::PVEMods::Collector::Nvidia  qw(get_nvidia_gpu_devices  collector_for_nvidia_devices);
use PVE::PVEMods::Collector::Amd     qw(get_amd_gpu_devices    collector_for_amd_device);
use PVE::PVEMods::Collector::LmSensors qw(collector_for_temperature_sensors);
use PVE::PVEMods::Collector::Ups     qw(collector_for_ups);

our @EXPORT_OK = qw(
    pve_mods_starter
    pve_mods_run_service
    notify_pve_mods_worker
);

# Collector registry — only populated inside the worker process.
# Each forked child has its own copy; the parent never accesses this after forking.
my %collectors = ();

# GPU collectors the last device discovery decided should run. Compared with
# %collectors to notice collectors that died or never started.
my %expected_gpu_collectors = ();

# ============================================================================
# Public API (called from SensorInfo)
# ============================================================================

# Ensures the worker is running.  Starts it if necessary (double-checked locking).
sub pve_mods_starter {
    debug(__LINE__, "Checking if pve_mods_worker is already running");
    if (_worker_lock_file_exists()) {
        debug(__LINE__, "pve_mods_worker process already running, system is already started");
        return "pve_mods_worker process already running, system is already started";
    }
    debug(__LINE__, "PVE mod worker is not running. PVE Mod will be started.");

    startup_message();
    ensure_pve_mods_directory_exists();

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

    _pve_mods_worker();

    unlink($startup_lock);
    debug(__LINE__, "Released startup lock");
    debug(__LINE__, "pve_mods_worker started successfully, returning");
}

# Sends SIGUSR1 to the worker to reset the inactivity timer.
sub notify_pve_mods_worker {
    debug(__LINE__, "notify_pve_mods_worker called");
    unless (-f $pve_mods_worker_lock) {
        debug(__LINE__, "pve_mods_worker lock file does not exist");
        return;
    }

    debug(__LINE__, "pve_mods_worker lock file exists, reading PID");
    if (open my $fh, '<', $pve_mods_worker_lock) {
        my $pid = <$fh>;
        close $fh;
        chomp $pid if defined $pid;
        if (defined $pid && $pid =~ /^(\d+)$/) {
            my $clean_pid = $1;

            if (is_process_alive($clean_pid)) {
                debug(__LINE__, "Sending USR1 signal to pve_mods_worker PID $clean_pid");
                my $result = kill('USR1', $clean_pid);
                debug(__LINE__, "Signal result: $result");
            } else {
                debug(__LINE__,
                    "pve_mods_worker process $clean_pid is not alive, removing stale lock");
                unlink($pve_mods_worker_lock);
            }
        } else {
            debug(__LINE__,
                "pve_mods_worker lock is stale (PID: " . ($pid // 'undefined') . "), removing");
            unlink($pve_mods_worker_lock);
        }
    } else {
        debug(__LINE__, "Failed to open pve_mods_worker lock file: $!");
    }
}

# Runs the worker in the foreground, for the pve-mods-gpu-history systemd
# service. Unlike pve_mods_starter() it does not detach, so systemd supervises
# it. An already running (UI-started) worker is replaced so only one exists.
sub pve_mods_run_service {
    ensure_pve_mods_directory_exists();

    if (_worker_lock_file_exists()) {
        my $old_pid = read_lock_pid($pve_mods_worker_lock);
        if (defined $old_pid && $old_pid =~ /^(\d+)$/ && $1 != $$) {
            my $pid = $1;
            debug(__LINE__, "Replacing running worker PID $pid with the service worker");
            kill('TERM', $pid);
            for (1 .. 50) {
                last unless is_process_alive($pid);
                select(undef, undef, undef, 0.1);
            }
            # The old worker removes the working directory when it exits
            ensure_pve_mods_directory_exists();
        }
    }

    my $fh = acquire_exclusive_lock($pve_mods_worker_lock, 'pve_mods_worker lock');
    die "Could not acquire the pve_mods_worker lock\n" unless $fh;
    print $fh "$$\n";
    close($fh);

    $0 = "pve_mods_worker_controller";
    _pve_mods_keep_alive();
    exit(0);
}

# ============================================================================
# Worker process management
# ============================================================================

sub _worker_lock_file_exists {
    return 0 unless -f $pve_mods_worker_lock;

    my $pid = read_lock_pid($pve_mods_worker_lock);
    if (!defined $pid || $pid !~ /^(\d+)$/) {
        debug(__LINE__, "Worker lock is invalid (PID: " . ($pid // 'undefined') . "), removing");
        unlink($pve_mods_worker_lock);
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

    unlink($pve_mods_worker_lock);
    return 0;
}

# Double-forks so the worker is reparented to init (PID 1) instead of the
# caller; init reaps it on exit, so it never lingers as a <defunct> zombie.
sub _pve_mods_worker {
    debug(__LINE__, "_pve_mods_worker called");

    my $pve_mods_worker_fh =
        acquire_exclusive_lock($pve_mods_worker_lock, 'pve_mods_worker lock');
    return unless $pve_mods_worker_fh;
    print $pve_mods_worker_fh "$$\n";
    close($pve_mods_worker_fh);

    debug(__LINE__, "Forking intermediate process for pve_mods_worker");
    my $intermediate_pid = fork();

    unless (defined $intermediate_pid) {
        debug(__LINE__, "Failed to fork intermediate pve_mods_worker process: $!");
        unlink($pve_mods_worker_lock);
        return;
    }

    if ($intermediate_pid == 0) {
        # Intermediate child: detach into its own session, fork the real
        # worker, then exit immediately so the worker is reparented to init.
        setsid();

        my $worker_pid = fork();
        unless (defined $worker_pid) {
            debug(__LINE__, "Failed to fork pve_mods_worker process: $!");
            unlink($pve_mods_worker_lock);
            POSIX::_exit(1);
        }

        if ($worker_pid == 0) {
            # Grandchild — the actual worker
            $0 = "pve_mods_worker_controller";
            if (open my $fh, '>', $pve_mods_worker_lock) {
                print $fh "$$\n";
                close $fh;
                debug(__LINE__, "Wrote pve_mods_worker PID to lock file: $pve_mods_worker_lock");
            } else {
                debug(__LINE__, "Failed to write pve_mods_worker lock file: $!");
            }
            debug(__LINE__, "Worker process forked, calling _pve_mods_keep_alive");
            _pve_mods_keep_alive();
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
        debug(__LINE__, "pve_mods_worker process started successfully");
    } else {
        debug(__LINE__, "Intermediate pve_mods_worker process exited with status $status");
    }
}

# ============================================================================
# Worker keep-alive loop
# ============================================================================

sub _pve_mods_keep_alive {
    $process_type = 'worker';
    debug(__LINE__, "pve_mods_worker process started with PID $$");

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
        debug(__LINE__, "pve_mods_worker received SIGTERM, shutting down");
        _stop_child_collectors();
        unlink($pve_mods_worker_lock) if -f $pve_mods_worker_lock;
        exit(0);
    };
    $SIG{INT} = sub {
        debug(__LINE__, "pve_mods_worker received SIGINT, shutting down");
        _stop_child_collectors();
        unlink($pve_mods_worker_lock) if -f $pve_mods_worker_lock;
        exit(0);
    };

    _reap_orphaned_collectors();

    debug(__LINE__, "Worker starting all collectors");
    _initialise_sensors_collector();
    _initialise_graphics_collectors();
    _initialise_ups_collector();
    debug(__LINE__, "All collectors started by worker");

    debug(__LINE__,
        "Entering pve_mods_worker loop, timeout=$config{intervals}{collector_timeout}s");

    # With GPU history enabled the worker never idles out, so the RRD keeps
    # recording without anyone viewing the UI. The sensors and UPS collectors
    # are only needed for the UI and still stop while it is idle.
    my $record_history      = ($config{gpu}{gpu_history}
        && ($config{gpu}{intel_enabled} || $config{gpu}{amd_enabled} || $config{gpu}{nvidia_enabled}))
        ? 1 : 0;
    my $ui_collectors_idle  = 0;
    my $last_gpu_check      = time();

    while (1) {
        debug(__LINE__, "pve_mods_worker loop start: checking activity");

        my $idle_time = time() - $last_activity;
        debug(__LINE__,
            "pve_mods_worker loop: idle_time=${idle_time}s, "
            . "timeout=$config{intervals}{collector_timeout}s");

        if ($idle_time > $config{intervals}{collector_timeout}) {
            if ($record_history) {
                unless ($ui_collectors_idle) {
                    debug(__LINE__, "Idle: stopping sensors/UPS collectors, GPU history keeps recording");
                    _stop_named_collectors('sensors', 'ups');
                    unlink($sensors_state_file, $ups_state_file);
                    $ui_collectors_idle = 1;
                }
            } else {
                debug(__LINE__, "Timeout reached, stopping collectors");
                _stop_child_collectors();
                debug(__LINE__, "Collectors stopped, exiting pve_mods_worker");
                unlink($pve_mods_worker_lock) if -f $pve_mods_worker_lock;
                exit(0);
            }
        } elsif ($ui_collectors_idle) {
            debug(__LINE__, "Activity resumed: restarting sensors/UPS collectors");
            _initialise_sensors_collector();
            _initialise_ups_collector();
            $ui_collectors_idle = 0;
        }

        # Rediscover GPUs and restart collectors that died or never started (for
        # example a driver that was not ready at boot), so history has no
        # permanent gaps.
        if ($record_history && time() - $last_gpu_check >= 30) {
            $last_gpu_check = time();
            my @missing = grep { !exists $collectors{$_} } keys %expected_gpu_collectors;
            if (!%expected_gpu_collectors || @missing) {
                debug(__LINE__, "GPU collectors missing (" . (join(', ', @missing) || 'none discovered yet')
                    . "), running discovery again");
                _initialise_graphics_collectors();
            }
        }
        sleep(1);
    }

    debug(__LINE__, "pve_mods_worker loop exited unexpectedly!");
}

# Stops only the named collectors, leaving the rest and the working directory.
sub _stop_named_collectors {
    my (@names) = @_;

    my @pids;
    foreach my $name (@names) {
        next unless exists $collectors{$name};
        push @pids, $collectors{$name};
        delete $collectors{$name};
    }
    return unless @pids;

    kill('TERM', $_) foreach grep { kill(0, $_) } @pids;

    my $start = time();
    while (time() - $start < 2) {
        last unless grep { is_process_alive($_) } @pids;
        select(undef, undef, undef, 0.1);
    }
    foreach my $pid (@pids) {
        kill('KILL', $pid) if is_process_alive($pid);
    }
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

    %expected_gpu_collectors = ();
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

        $expected_gpu_collectors{$device_name} = 1;
        my $pid = _start_collector($device_name, $type, $collector_sub, $device);
        $started_count++ if $pid;
    }

    # NVIDIA — single collector for all GPUs
    if (@nvidia_devices) {
        $expected_gpu_collectors{'nvidia-all'} = 1;
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

    if (-d $pve_mods_working_dir) {
        remove_tree($pve_mods_working_dir, { error => \my $err });
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
