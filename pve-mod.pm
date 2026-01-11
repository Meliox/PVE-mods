package PVE::API2::GPUMonitor;

use strict;
use warnings;
use JSON;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time);
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use File::Path qw(remove_tree);

# debug configuration - set to 0 to disable all _debug output
my $debug_ENABLED = 1;
my $VERSION = '1.0.0';

# ============================================================================
# Configuration
# ============================================================================
my %config = (
    gpu => {
        intel_enabled => 1,
        amd_enabled => 0,
        nvidia_enabled => 1,
    },
    debug => {
        nvidia_mode => 1,
        nvidia_devices_file => '/tmp/nvidia-smi-devices.csv',
        nvidia_output_file => '/tmp/nvidia-smi-output.csv',
        sensors_mode => 0,
        sensors_output_file => '/tmp/sensors-output.json',
    },
    intervals => {
        data_pull => 1,          # seconds between data pulls
        collector_timeout => 10, # stop collectors after N seconds of inactivity
    },
    ups => {
        enabled => 1,
        device_name => 'ups@192.168.3.2',
    },
    paths => {
        working_dir => '/run/pveproxy/pve-mod',
    },
);

# ============================================================================
# Derived paths and runtime state
# ============================================================================

# Derived paths from configuration
my $pve_mod_working_dir = $config{paths}{working_dir};
my $stats_dir = $pve_mod_working_dir;
my $state_file = "$pve_mod_working_dir/stats.json";
my $sensors_state_file = "$pve_mod_working_dir/sensors.json";
my $ups_state_file = "$pve_mod_working_dir/ups.json";
my $pve_mod_worker_lock = "$pve_mod_working_dir/pve_mod_worker.lock";
my $startup_lock = "$pve_mod_working_dir/startup.lock";

# Runtime state variables
my $process_type = 'main';  # 'main', 'worker', or 'collector'
my $last_snapshot = {};
my $last_mtime = 0;
my $last_get_graphic_stats_time = 0;
my $pve_mod_worker_pid;
my $pve_mod_worker_running = 0;

# Collector registry - only populated in worker process
my %collectors = ();  # key: device/card name, value: PID

# ============================================================================
# Shared Utility Functions
# ============================================================================

# debug function showing line number and call chain
# Usage: _debug(__LINE__, "message")
sub _debug {
    return unless $debug_ENABLED;
    
    my ($line, $message) = @_;
    
    # Get function call chain
    my @caller1 = caller(1);  # who called _debug()
    my @caller2 = caller(2);  # parent of caller
    
    my $sub1 = $caller1[3] || 'main';
    my $sub2 = $caller2[3];
    
    $sub1 =~ s/.*:://;  # Remove package prefix
    
    if (defined $sub2) {
        $sub2 =~ s/.*:://;
        warn "[$sub2 -> $sub1:$line] $message\n";
    } else {
        # No parent caller (called from top level)
        warn "[$sub1:$line] $message\n";
    }
}

sub read_sysfs {
    my ($path) = @_;
    
    return "unknown" unless defined $path && -f $path;
    
    if (open my $fh, '<', $path) {
        my $value = <$fh>;
        close $fh;
        
        if (defined $value) {
            chomp $value;
            # Remove leading/trailing whitespace
            $value =~ s/^\s+|\s+$//g;
            return $value ne '' ? $value : "unknown";
        }
    }
    
    return "unknown";
}

sub _is_process_alive {
    my ($pid) = @_;
    return -d "/proc/$pid";
}

sub _read_lock_pid {
    my ($lock_path) = @_;
    
    return undef unless open(my $fh, '<', $lock_path);
    
    my $pid = <$fh>;
    close($fh);
    chomp $pid if defined $pid;
    
    return $pid;
}

sub _acquire_exclusive_lock {
    my ($lock_path, $purpose) = @_;
    $purpose //= 'lock';
    
    my $fh;

    # Try to create lock file exclusively
    if (sysopen($fh, $lock_path, O_CREAT|O_EXCL|O_WRONLY, 0644)) {
        _debug(__LINE__, "Acquired $purpose on first try");
        return $fh;
    }
    
    # Lock file creation failed - check if it's stale or held by another process
    _debug(__LINE__, ucfirst($purpose) . " exists, checking if stale");
    
    my $lock_pid = _read_lock_pid($lock_path);
    
    if (!defined $lock_pid) {
        _debug(__LINE__, "Could not read $purpose file: $!");
        return undef;
    }
    
    if ($lock_pid eq '' || $lock_pid !~ /^\d+$/) {
        _debug(__LINE__, "Invalid PID in $purpose: '" . ($lock_pid // 'undefined') . "', removing");
        unlink($lock_path);
    } elsif (_is_process_alive($lock_pid)) {
        _debug(__LINE__, ucfirst($purpose) . " holder PID $lock_pid is still alive");
        return undef;
    } else {
        _debug(__LINE__, ucfirst($purpose) . " holder PID $lock_pid is dead, removing stale lock");
        unlink($lock_path);
    }
    
    # Try to acquire lock again after cleanup
    unless (sysopen($fh, $lock_path, O_CREAT|O_EXCL|O_WRONLY, 0644)) {
        _debug(__LINE__, "Failed to acquire $purpose on retry: $!");
        return undef;
    }
    
    _debug(__LINE__, "Acquired $purpose after removing stale lock");
    return $fh;
}

sub _is_lock_stale {
    my ($lock_path) = @_;
    
    return 0 unless open(my $fh, '<', $lock_path);
    
    my $lock_pid = <$fh>;
    chomp $lock_pid if defined $lock_pid;
    close($fh);
    
    # Invalid or missing PID
    return 1 unless defined $lock_pid && $lock_pid =~ /^\d+$/;
    
    # Valid PID but process is dead
    return !_is_process_alive($lock_pid);
}

sub _ensure_pve_mod_directory_exists {
    unless (-d $pve_mod_working_dir) {
        _debug(__LINE__, "Creating directory $pve_mod_working_dir");
        unless (mkdir($pve_mod_working_dir, 0755)) {
            _debug(__LINE__, "Failed to create $pve_mod_working_dir: $!. PVE Mod cannot start.");
            die "Failed to create $pve_mod_working_dir: $!";
        }
        _debug(__LINE__, "Directory $pve_mod_working_dir created");
    } else {
        _debug(__LINE__, "Directory $pve_mod_working_dir already exists");
    }
}

# Generic function to check if required executable exists
# Returns 1 if executable exists or debug mode is enabled for that type
# Returns 0 if executable doesn't exist and debug mode is not enabled
sub _check_executable {
    my ($exec_path, $type, $debug_mode_enabled, $debug_file) = @_;
    
    # If debug mode is enabled for this type, check if debug file exists instead
    if (defined $debug_mode_enabled && $debug_mode_enabled) {
        if (defined $debug_file && -f $debug_file) {
            _debug(__LINE__, "Debug mode enabled for $type, using debug file: $debug_file");
            return 1;
        } elsif (defined $debug_file) {
            _debug(__LINE__, "Debug mode enabled for $type but debug file missing: $debug_file");
            return 0;
        } else {
            _debug(__LINE__, "Debug mode enabled for $type, skipping executable check for $exec_path");
            return 1;
        }
    }
    
    # Normal mode: check if executable exists
    unless (-x $exec_path) {
        _debug(__LINE__, "$type executable not found or not executable: $exec_path");
        return 0;
    }
    
    _debug(__LINE__, "$type executable found: $exec_path");
    return 1;
}

sub _pve_mod_hello {
    _debug(__LINE__, "PVE Mod is being started. Version $VERSION");
}

# Setup common signal handlers for collector processes
sub _setup_collector_signals {
    my ($name, $shutdown_ref, $extra_cleanup) = @_;
    
    $SIG{TERM} = sub {
        _debug(__LINE__, "Collector $name received SIGTERM");
        $$shutdown_ref = 1;
        $extra_cleanup->() if $extra_cleanup;
    };
    $SIG{INT} = sub {
        _debug(__LINE__, "Collector $name received SIGINT");
        $$shutdown_ref = 1;
        $extra_cleanup->() if $extra_cleanup;
    };
}

# Safe JSON file write with error handling
sub _safe_write_json {
    my ($filepath, $data, $pretty) = @_;
    $pretty //= 1;
    
    eval {
        open my $fh, '>', $filepath or die "Failed to open $filepath: $!";
        my $json = $pretty ? JSON->new->pretty->encode($data) : encode_json($data);
        print $fh $json;
        close $fh;
        _debug(__LINE__, "Wrote JSON to $filepath");
    };
    if ($@) {
        _debug(__LINE__, "Error writing to $filepath: $@");
        return 0;
    }
    return 1;
}

# Safe JSON file read with error handling
sub _safe_read_json {
    my ($filepath, $as_string) = @_;
    
    return unless -f $filepath;
    
    my $result;
    eval {
        open my $fh, '<', $filepath or die "Failed to open $filepath: $!";
        local $/;
        my $json = <$fh>;
        close $fh;
        
        if ($as_string) {
            $result = $json;
        } else {
            $result = decode_json($json);
        }
        _debug(__LINE__, "Read JSON from $filepath");
    };
    if ($@) {
        _debug(__LINE__, "Error reading $filepath: $@");
        return;
    }
    return $result;
}

# Parse CSV line with trimming
sub _parse_csv_line {
    my ($line, $expected_fields) = @_;
    
    return unless $line;
    $line =~ s/^\s+|\s+$//g;
    
    my @values = map { s/^\s+|\s+$//gr } split(/,/, $line);
    
    return unless !$expected_fields || @values >= $expected_fields;
    return @values;
}

# Enhance sensors data with cached lookups (unified for drives and CPUs)
sub _enhance_sensors_with_cache {
    my ($sensors_output, $cache_ref, $pattern, $lookup_sub, $field_names) = @_;
    
    $cache_ref //= {};
    
    my $sensors_data = _safe_read_json(\$sensors_output);
    return $sensors_output unless $sensors_data;
    
    # For string input, parse it
    unless (ref $sensors_data eq 'HASH') {
        eval { $sensors_data = decode_json($sensors_output); };
        return $sensors_output if $@;
    }
    
    my @entries = grep { /$pattern/ } keys %{$sensors_data};
    _debug(__LINE__, "Found " . scalar(@entries) . " entries matching pattern");
    
    foreach my $entry (@entries) {
        my $metadata;
        
        # Check cache first
        if (exists $cache_ref->{$entry}) {
            $metadata = $cache_ref->{$entry};
            _debug(__LINE__, "Using cached info for $entry");
        } else {
            # Lookup information
            $metadata = $lookup_sub->($entry);
            $cache_ref->{$entry} = $metadata if $metadata;
        }
        
        # Add metadata to sensors data
        if ($metadata && exists $sensors_data->{$entry}) {
            foreach my $key (keys %$metadata) {
                $sensors_data->{$entry}->{$key} = $metadata->{$key};
            }
            _debug(__LINE__, "Enhanced $entry with metadata");
        }
    }
    
    return JSON->new->pretty->canonical->encode($sensors_data);
}

# ============================================================================
# Intel GPU Support
# ============================================================================

# Parse Intel GPU line output format
sub _parse_intel_gpu_line {
    my ($line) = @_;
    
    # Expected format (with aligned columns):
    # Freq MHz      IRQ RC6     Power W             RCS             BCS             VCS            VECS
    # req  act       /s   %   gpu   pkg       %  se  wa       %  se  wa       %  se  wa       %  se  wa
    #   0    0        0   0  0.00  7.47    0.00   0   0    0.00   0   0    0.00   0   0    0.00   0   0
    
    # Remove leading/trailing whitespace
    $line =~ s/^\s+|\s+$//g;
    
    # Split by whitespace and filter empty values
    my @values = grep { $_ ne '' } split(/\s+/, $line);
    
    # Expected: req(0) act(1) irq(2) rc6(3) gpu(4) pkg(5) rcs%(6) rcs_se(7) rcs_wa(8) 
    #           bcs%(9) bcs_se(10) bcs_wa(11) vcs%(12) vcs_se(13) vcs_wa(14) vecs%(15) vecs_se(16) vecs_wa(17)
    
    return unless @values >= 18;
    
    my $stats = {
        frequency => {
            requested => $values[0] + 0.0,
            actual => $values[1] + 0.0,
            unit => "MHz"
        },
        interrupts => {
            count => $values[2] + 0.0,
            unit => "irq/s"
        },
        rc6 => {
            value => $values[3] + 0.0,
            unit => "%"
        },
        power => {
            GPU => $values[4] + 0.0,
            Package => $values[5] + 0.0,
            unit => "W"
        },
        engines => {
            "Render/3D" => {
                busy => $values[6] + 0.0,
                sema => $values[7] + 0.0,
                wait => $values[8] + 0.0,
                unit => "%"
            },
            Blitter => {
                busy => $values[9] + 0.0,
                sema => $values[10] + 0.0,
                wait => $values[11] + 0.0,
                unit => "%"
            },
            Video => {
                busy => $values[12] + 0.0,
                sema => $values[13] + 0.0,
                wait => $values[14] + 0.0,
                unit => "%"
            },
            VideoEnhance => {
                busy => $values[15] + 0.0,
                sema => $values[16] + 0.0,
                wait => $values[17] + 0.0,
                unit => "%"
            }
        },
        clients => {}
    };
    
    return $stats;
}

# Get list of Intel GPU devices
sub _get_intel_gpu_devices {
    my @devices = ();
    
    # Check if intel_gpu_top is available (debug mode doesn't apply to device listing)
    return @devices unless _check_executable('/usr/bin/intel_gpu_top', 'Intel GPU');
    
    _debug(__LINE__, "Getting Intel GPU devices");
    if (open my $fh, '-|', 'intel_gpu_top -L') {
        while (<$fh>) {
            chomp;
            # Parse: "card0  Intel Alderlake_n (Gen12)  pci:vendor=8086,device=46D0,card=0"
            # or: "card0  Intel Alderlake_n (Gen12)  pci:0000:00:02.0"
            if (/^(card\d+)\s+(.+?)\s+(pci:[^\s]+)/) {
                my $card = $1;
                my $name = $2;
                my $path = $3;
                push @devices, {
                    card => $card,
                    name => $name,
                    path => $path,
                    drm_path => "/dev/dri/$card"
                };
                _debug(__LINE__, "Found Intel device: $card -> $name ($path)");
            }
        }
        close $fh;
    } else {
        _debug(__LINE__, "Failed to run intel_gpu_top -L: $!");
    }
    
    return @devices;
}

sub _collector_for_intel_device {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-gpu-intel-$device->{card}";

    my $drm_dev = "drm:/dev/dri/$device->{card}";
    my $intel_gpu_top_pid = undef;
    
    # Each device writes to its own file
    my $device_state_file = "$pve_mod_working_dir/stats-$device->{card}.json";
    
    _debug(__LINE__, "Collector started for device: $drm_dev, writing to $device_state_file");
    
    # Set up signal handlers for graceful shutdown
    my $shutdown = 0;
    _setup_collector_signals($device->{card}, \$shutdown, sub {
        kill 'TERM', $intel_gpu_top_pid if defined $intel_gpu_top_pid && $intel_gpu_top_pid > 0;
    });
    
    # Run intel_gpu_top once and keep reading from it
    _debug(__LINE__, "About to open pipe to intel_gpu_top");
    my $intel_pull_interval = $config{intervals}{data_pull} * 1000; # in milliseconds
    $intel_gpu_top_pid = open(my $fh, '-|', "intel_gpu_top -d $drm_dev -s $intel_pull_interval -l 2>&1");
    
    unless (defined $intel_gpu_top_pid && $intel_gpu_top_pid > 0) {
        _debug(__LINE__, "Failed to run intel_gpu_top for $drm_dev: $!");
        exit 1;
    }
    
    _debug(__LINE__, "Pipe opened successfully, PID=$intel_gpu_top_pid");
    
    my $line_count = 0;
    my $node_name = "node0";  # You may want to generate this based on device index
    
    while (my $line = <$fh>) {
        last if $shutdown;
        
        $line_count++;
        chomp $line;
        
        # Skip header lines
        next if $line =~ /MHz|IRQ|RC6|Power|RCS|BCS|VCS|VECS|req\s+act|^\s*$/;
        
        # Check if this is a data line
        if ($line =~ /^\s*[\d\s\.]+$/) {
            my $stats = _parse_intel_gpu_line($line);
            
            if ($stats) {
                # Build device-specific structure (just the node, not the full Graphics/Intel hierarchy)
                my $device_data = {
                    $node_name => {
                        name => $device->{name},
                        device_path => $device->{path},
                        drm_path => $device->{drm_path},
                        stats => $stats
                    }
                };
                
                # Write to device-specific file
                _safe_write_json($device_state_file, $device_data);
            }
        }
    }
    
    close $fh;
    _debug(__LINE__, "Collector for $device->{card} shutting down");
    exit 0;
}

# Parse information for graphical presentation. 
sub _parse_graphic_info {
    my ($line) = @_;

    # Create a RRD Database (One-Time Setup)

    # Collect intel GPU data and save it into the database

    return undef;
}

# ============================================================================
# AMD GPU Support (Placeholder)
# ============================================================================

sub _get_amd_gpu_devices {
    # TODO: Implement AMD GPU detection
    # Use rocminfo or similar tools to detect AMD GPUs
    _debug(__LINE__, "AMD GPU support not yet implemented");
    return ();
}

sub _parse_amd_gpu_line {
    my ($line) = @_;
    # TODO: Implement AMD GPU line parsing
    # Parse rocm-smi or similar output
    _debug(__LINE__, "AMD GPU line parsing not yet implemented");
    return undef;
}

sub _collector_for_amd_device {
    my ($device) = @_;
    # TODO: Implement AMD GPU collector
    _debug(__LINE__, "AMD GPU collector not yet implemented");
    exit 0;
}

# ============================================================================
# NVIDIA GPU Support
# ============================================================================

sub get_nvidia_gpu_devices {
    my @devices = ();
    
    # Expected format (CSV with header):
    # index, name
    # 0, NVIDIA GeForce RTX 3080
    # 1, NVIDIA RTX A4000
    
    # Check if nvidia-smi is available (or debug mode with debug file)
    unless (_check_executable('/usr/bin/nvidia-smi', 'NVIDIA', $config{debug}{nvidia_mode}, $config{debug}{nvidia_devices_file})) {
        return @devices;
    }
    
    if ($config{debug}{nvidia_mode} && -f $config{debug}{nvidia_devices_file}) {
        _debug(__LINE__, "Debug mode: reading NVIDIA GPU devices from $config{debug}{nvidia_devices_file}");
        if (open my $fh, '<', $config{debug}{nvidia_devices_file}) {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                
                # Skip header line and empty lines
                next if $line_num == 1 || /^\s*$/;
                
                # Parse CSV using shared helper
                my @values = _parse_csv_line($_, 2);
                if (@values) {
                    push @devices, {
                        index => $values[0],
                        name => $values[1],
                    };
                    _debug(__LINE__, "Found NVIDIA GPU device (debug): $values[1] -> (index: $values[0])");
                }
            }
            close $fh;
        } else {
            _debug(__LINE__, "Failed to open debug file $config{debug}{nvidia_devices_file}: $!");
        }
    } else {
        # Use nvidia-smi to get device list
        if (open my $fh, '-|', 'nvidia-smi --query-gpu=index,name --format=csv') {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                
                # Skip header line and empty lines
                next if $line_num == 1 || /^\s*$/;
                
                # Parse CSV using shared helper
                my @values = _parse_csv_line($_, 2);
                if (@values) {
                    push @devices, {
                        index => $values[0],
                        name => $values[1],
                    };
                    _debug(__LINE__, "Found NVIDIA GPU device: $values[1] -> (index: $values[0])");
                }
            }
            close $fh;
        }
    }
    
    return @devices;
}

sub parse_nvidia_gpu_line {
    my ($line) = @_;

    # Expected format (CSV) for multiple GPUs:
    # index, name, temperature.gpu, utilization.gpu, utilization.memory, memory.used, memory.total, power.draw, power.limit, fan.speed
    #0, NVIDIA GeForce RTX 3080, 62, 79, 44, 8260, 10240, 268.12, 320.00, 67

    # Parse CSV using shared helper
    my @values = _parse_csv_line($line, 10);
    return unless @values;
    
    my $stats = {
        index => $values[0] + 0,
        name => $values[1],
        temperature => {
            gpu => $values[2] + 0.0,
            unit => "°C"
        },
        utilization => {
            gpu => $values[3] + 0.0,
            memory => $values[4] + 0.0,
            unit => "%"
        },
        memory => {
            used => $values[5] + 0.0,
            total => $values[6] + 0.0,
            unit => "MiB"
        },
        power => {
            draw => $values[7] + 0.0,
            limit => $values[8] + 0.0,
            unit => "W"
        },
        fan => {
            speed => $values[9] + 0.0,
            unit => "%"
        }
    };
    
    return $stats;
}

sub _get_and_write_nvidia_stats {
    my ($devices) = @_;
    my @all_stats;
    
    if ($config{debug}{nvidia_mode} && -f $config{debug}{nvidia_output_file}) {
        # Debug mode: read all GPUs from single file
        _debug(__LINE__, "Debug mode: reading NVIDIA GPU stats from $config{debug}{nvidia_output_file}");
        if (open my $fh, '<', $config{debug}{nvidia_output_file}) {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                
                # Skip header and empty lines
                next if $line_num == 1 || /^\s*$/;
                
                # Parse the stats line
                my $stats = parse_nvidia_gpu_line($_);
                push @all_stats, $stats if $stats;
            }
            close $fh;
        } else {
            _debug(__LINE__, "Failed to open debug file $config{debug}{nvidia_output_file}: $!");
        }
    } else {
        # Production mode: check if nvidia-smi is available before querying
        unless (_check_executable('/usr/bin/nvidia-smi', 'NVIDIA')) {
            _debug(__LINE__, "nvidia-smi not available, cannot collect stats");
            return 0;
        }
        
        # Query all GPUs at once
        my $query = 'index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,fan.speed';
        my $cmd = "nvidia-smi --query-gpu=$query --format=csv,nounits";
        
        if (open my $fh, '-|', $cmd) {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                
                # Skip header and empty lines
                next if $line_num == 1 || /^\s*$/;
                
                # Parse the stats line
                my $stats = parse_nvidia_gpu_line($_);
                push @all_stats, $stats if $stats;
            }
            close $fh;
        }
    }
    
    # Write each GPU's stats to its own file
    foreach my $stats (@all_stats) {
        my $device_index = $stats->{index};
        
        # Untaint device_index for file operations (validate it's a number)
        unless ($device_index =~ /^(\d+)$/) {
            _debug(__LINE__, "Invalid device index: $device_index, skipping");
            next;
        }
        $device_index = $1;  # Now untainted
        
        my $node_name = "gpu$device_index";
        my $device_state_file = "$pve_mod_working_dir/stats-nvidia$device_index.json";
        
        # Find device name from devices array
        my $device_name = $stats->{name};  # Fallback to name from stats
        foreach my $dev (@$devices) {
            if ($dev->{index} == $device_index) {
                $device_name = $dev->{name};
                last;
            }
        }
        
        # Build device-specific structure
        my $device_data = {
            $node_name => {
                name => $device_name,
                index => $device_index,
                stats => $stats
            }
        };
        
        # Write to device-specific file
        _safe_write_json($device_state_file, $device_data);
    }
    
    unless (@all_stats) {
        _debug(__LINE__, "No valid NVIDIA GPU stats collected");
    }
    
    return scalar(@all_stats);
}

sub _collector_for_nvidia_devices {
    my ($devices) = @_;
    $process_type = 'collector';
    
    $0 = "collector-gpu-nvidia-all";
    
    _debug(__LINE__, "NVIDIA collector started for " . scalar(@$devices) . " GPU(s)");
    
    # Set up signal handlers for graceful shutdown
    my $shutdown = 0;
    _setup_collector_signals('nvidia-all', \$shutdown);
    
    # Expected CSV format (with header):
    # index, name, temperature.gpu, utilization.gpu, utilization.memory, memory.used, memory.total, power.draw, power.limit, fan.speed
    # 0, NVIDIA GeForce RTX 3080, 62, 79, 44, 8260, 10240, 268.12, 320.00, 67
    # 1, NVIDIA RTX A4000, 58, 45, 32, 4120, 16384, 145.50, 200.00, 55
    
    while (!$shutdown) {
        # Collect and write NVIDIA GPU stats
        _get_and_write_nvidia_stats($devices);
        
        sleep $config{intervals}{data_pull} unless $shutdown;
    }
    
    _debug(__LINE__, "NVIDIA collector shutting down");
    exit 0;
}

# ============================================================================
# Temperature Sensors
# ============================================================================

sub _collector_for_temperature_sensors {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-temperature-sensors";

    _debug(__LINE__, "Temperature sensor collector started");

    # Check if lm-sensors is available (or debug mode with debug file)
    unless (_check_executable('/usr/bin/sensors', 'lm-sensors', $config{debug}{sensors_mode}, $config{debug}{sensors_output_file})) {
        _debug(__LINE__, "sensors not available and not in debug mode, exiting");
        exit(1);
    }

    # Cache for drive and CPU names
    my %cache_ref;

    # Set up signal handlers for graceful shutdown
    my $shutdown = 0;
    _setup_collector_signals('temperature-sensors', \$shutdown);

    while (!$shutdown) {
        my $sensorsData = _get_temperature_sensors(\%cache_ref);

        # Write to sensors state file (as string, not parsed JSON)
        eval {
            open my $ofh, '>', $sensors_state_file or die "Failed to open $sensors_state_file: $!";
            print $ofh $sensorsData;
            close $ofh;
            _debug(__LINE__, "Wrote temperature sensor data to $sensors_state_file");
        };
        if ($@) {
            _debug(__LINE__, "Error writing temperature sensor data: $@");
        }

        sleep $config{intervals}{data_pull} unless $shutdown;
    }

    _debug(__LINE__, "Temperature sensor collector shutting down");
    exit 0;
}

sub _get_temperature_sensors {
    my ($cache_ref) = @_;
    
    my $sensorsOutput;

    # Collect sensor data from lm-sensors
    if ($config{debug}{sensors_mode} && -f $config{debug}{sensors_output_file}) {
        # Debug mode: read from file
        _debug(__LINE__, "Debug mode: reading sensors data from $config{debug}{sensors_output_file}");
        if (open my $fh, '<', $config{debug}{sensors_output_file}) {
            local $/;
            $sensorsOutput = <$fh>;
            close $fh;
            _debug(__LINE__, "Read sensors data from debug file, length: " . length($sensorsOutput) . " bytes");
        } else {
            _debug(__LINE__, "Failed to open debug file $config{debug}{sensors_output_file}: $!");
            $sensorsOutput = '{}';
        }
    } else {
        # Production mode: call sensors command
        $sensorsOutput = `sensors -j 2>/dev/null | python3 -m json.tool`;
        _debug(__LINE__, "Raw sensors output collected from command");
    }
    
    _debug(__LINE__, "Raw sensors output collected");

    # sanitize output
    my $sensorsData = _sanitize_sensors($sensorsOutput);

    _debug(__LINE__, "Sanitized sensors output");

    # translate drive names (pass cache reference)
    $sensorsData = _get_drive_names($sensorsData, $cache_ref);

    _debug(__LINE__, "Translated drive names in sensors output");

    # translate CPU names (pass cache reference)
    $sensorsData = _get_cpu_name($sensorsData, $cache_ref);  

    _debug(__LINE__, "Translated CPU names in sensors output");  

    # Good, now add a master node called lm sensors exhanced by PVE MOD
    my $sensors_json;
    eval {
        $sensors_json = decode_json($sensorsData);
    };
    if ($@) {
        _debug(__LINE__, "Failed to parse final sensors JSON: $@");
        return $sensorsData;  # Return original output on parse error
    }
    my $enhanced_data = {
        "PVE MOD lm-sensors Enhanced" => $sensors_json
    };
    $sensorsData = JSON->new->pretty->encode($enhanced_data);



    return $sensorsData;
}

sub _sanitize_sensors {
    my ($sensorsOutput) = @_;

    # Sanitize JSON output to handle common lm-sensors parsing issues
    # Replace ERROR lines with placeholder values
    $sensorsOutput =~ s/ERROR:.+\s(\w+):\s(.+)/\"$1\": 0.000,/g;
    $sensorsOutput =~ s/ERROR:.+\s(\w+)!/\"$1\": 0.000,/g;
    
    # Remove trailing commas before closing braces
    $sensorsOutput =~ s/,\s*(})/$1/g;
    
    # Replace NaN values with null for valid JSON
    $sensorsOutput =~ s/\bNaN\b/null/g;
    
    # Fix duplicate SODIMM keys by appending temperature sensor number
    # This prevents JSON key overwrites when multiple SODIMM sensors exist
    # Example: "SODIMM":{"temp3_input":34.0} becomes "SODIMM3":{"temp3_input":34.0}
    $sensorsOutput =~ s/\"SODIMM\":\{\"temp(\d+)_input\"/\"SODIMM$1\":\{\"temp$1_input\"/g;

    return $sensorsOutput;
}

sub _get_drive_names {
    my ($sensorsOutput, $cache_ref) = @_;
    
    # Use empty hash if no cache reference provided (shouldn't happen)
    $cache_ref //= {};
    
    my @drive_names;
    
    # Parse sensors output to extract drive entries
    my $sensors_data;
    eval {
        $sensors_data = decode_json($sensorsOutput);
    };
    if ($@) {
        _debug(__LINE__, "Failed to parse sensors JSON: $@");
        return $sensorsOutput;  # Return original output on parse error
    }
    
    # Extract drive entries from sensors data
    my @entries = grep { 
        /^drivetemp-scsi-/ || /^drivetemp-nvme-/ || /^nvme-pci-/ 
    } keys %{$sensors_data};
    
    _debug(__LINE__, "Found " . scalar(@entries) . " drive entries in sensors output");

    foreach my $entry (@entries) {
        my ($dev_path, $model, $serial) = ("unknown", "unknown", "unknown");
        
        # Check cache first
        if (exists $cache_ref->{$entry}) {
            my $cached = $cache_ref->{$entry};
            $dev_path = $cached->{device_path};
            $model = $cached->{model};
            $serial = $cached->{serial};
            _debug(__LINE__, "Using cached drive info for $entry");
        } else {
            # Lookup drive information
            
            # ----- SCSI/SATA -----
            if ($entry =~ /^drivetemp-scsi-(\d+)-(\d+)/) {
                my ($host, $id) = ($1, $2);
                my $scsi_path = "/sys/class/scsi_disk/$host:$id:0:0/device/block";

                if (opendir(my $sdh, $scsi_path)) {
                    my @devs = grep { /^sd/ } readdir($sdh);
                    closedir($sdh);
                    if (@devs) {
                        $dev_path = "/dev/$devs[0]";
                        $model  = read_sysfs("/sys/class/block/$devs[0]/device/model");
                        $serial = read_sysfs("/sys/class/block/$devs[0]/device/serial");
                    }
                }

            # ----- Numeric NVMe -----
            } elsif ($entry =~ /^drivetemp-nvme-(\d+)/) {
                my $nvme_index = $1;
                $dev_path = "/dev/nvme${nvme_index}n1";
                if (-e $dev_path) {
                    $model  = read_sysfs("/sys/class/block/nvme${nvme_index}n1/device/model");
                    $serial = read_sysfs("/sys/class/block/nvme${nvme_index}n1/device/serial");
                }

            # ----- PCI-style NVMe -----
            } elsif ($entry =~ /^nvme-pci-(\w+)/) {
                my $pci_addr = $1;
                
                # Convert short PCI address to pattern
                # nvme-pci-0600 -> 0000:06:00
                # Format: domain:bus:device (function is usually .0)
                my $pci_pattern;
                if ($pci_addr =~ /^([0-9a-f]{2})([0-9a-f]{2})$/i) {
                    # Short format like "0600" -> "06:00"
                    my ($bus, $dev) = ($1, $2);
                    $pci_pattern = sprintf("%04x:%02x:%02x", 0, hex($bus), hex($dev));
                    _debug(__LINE__, "Converted PCI address $pci_addr to pattern $pci_pattern");
                } else {
                    # Already in some other format, use as-is
                    $pci_pattern = $pci_addr;
                }
                
                # Try multiple approaches to find the NVMe device
                my $found = 0;
                
                # Approach 1: Check /sys/class/nvme/
                my $nvme_dir = "/sys/class/nvme";
                _debug(__LINE__, "Searching for NVMe devices in $nvme_dir matching PCI pattern $pci_pattern");
                if (opendir(my $ndh, $nvme_dir)) {
                    my @nvme_devs = grep { /^nvme\d+$/ && -d "$nvme_dir/$_" } readdir($ndh);
                    closedir($ndh);
                    
                    _debug(__LINE__, "Found NVMe devices: " . join(", ", @nvme_devs));

                    foreach my $nvme_dev (@nvme_devs) {
                        # Check if this nvme device matches our PCI address
                        my $device_link = readlink("$nvme_dir/$nvme_dev/device");
                        if ($device_link && $device_link =~ /$pci_pattern/) {
                            _debug(__LINE__, "NVMe device $nvme_dev matches PCI pattern $pci_pattern");
                            # Found matching device
                            $dev_path = "/dev/$nvme_dev" . "n1";
                            $model  = read_sysfs("$nvme_dir/$nvme_dev/model");
                            $serial = read_sysfs("$nvme_dir/$nvme_dev/serial");
                            $found = 1;
                            _debug(__LINE__, "Found NVMe device via /sys/class/nvme: $dev_path (matched $pci_pattern)");
                            last;
                        }
                        _debug(__LINE__, "NVMe device $nvme_dev did not match PCI pattern $pci_pattern");
                    }
                }
                
                # Approach 2: Try direct block device lookup if not found
                if (!$found && opendir(my $bdh, "/sys/class/block")) {
                    my @block_devs = grep { /^nvme\d+n\d+$/ } readdir($bdh);
                    closedir($bdh);
                    
                    foreach my $block_dev (@block_devs) {
                        my $device_link = readlink("/sys/class/block/$block_dev/device");
                        if ($device_link && $device_link =~ /$pci_pattern/) {
                            $dev_path = "/dev/$block_dev";
                            # For block devices, go up to the nvme controller for model/serial
                            my $nvme_ctrl = $block_dev;
                            $nvme_ctrl =~ s/n\d+$//;  # nvme0n1 -> nvme0
                            $model  = read_sysfs("/sys/class/nvme/$nvme_ctrl/model");
                            $serial = read_sysfs("/sys/class/nvme/$nvme_ctrl/serial");
                            $found = 1;
                            _debug(__LINE__, "Found NVMe device via /sys/class/block: $dev_path (matched $pci_pattern)");
                            last;
                        }
                    }
                }
                
                unless ($found) {
                    _debug(__LINE__, "Could not find device for nvme-pci-$pci_addr (pattern: $pci_pattern)");
                }
            } else {
                next; # unknown device type
            }
            
            # Cache the lookup result
            $cache_ref->{$entry} = {
                device_path => $dev_path,
                model => $model,
                serial => $serial
            };
            
            _debug(__LINE__, "Drive: $entry -> $dev_path (Model: $model, Serial: $serial)");
        }

        # Add to result array
        push @drive_names, [$entry, $dev_path, $model, $serial];
    }

    # Now enhance the sensors_data structure directly (not as string manipulation)
    foreach my $drive_entry (@drive_names) {
        my ($original_name, $dev_path, $model, $serial) = @$drive_entry;
        
        # Add metadata directly to the data structure
        if (exists $sensors_data->{$original_name}) {
            $sensors_data->{$original_name}->{device_path} = $dev_path;
            $sensors_data->{$original_name}->{model} = $model;
            $sensors_data->{$original_name}->{serial} = $serial;
            _debug(__LINE__, "Enhanced $original_name with drive info");
        }
    }

    # Re-encode as pretty JSON
    my $enhanced_json = JSON->new->pretty->canonical->encode($sensors_data);
    
    return $enhanced_json;
}

sub _get_cpu_name {
    my ($sensorsOutput, $cache_ref) = @_;
    
    # Use empty hash if no cache reference provided
    $cache_ref //= {};
    
    # Parse sensors output to extract CPU entries
    my $sensors_data;
    eval {
        $sensors_data = decode_json($sensorsOutput);
    };
    if ($@) {
        _debug(__LINE__, "Failed to parse sensors JSON: $@");
        return $sensorsOutput;  # Return original output on parse error
    }
    
    # Extract CPU entries from sensors data
    my @entries = grep { /^coretemp-isa-/ || /^k10temp-pci-/ } keys %{$sensors_data};
    
    _debug(__LINE__, "Found " . scalar(@entries) . " CPU entries in sensors output");
    
    foreach my $entry (@entries) {
        my ($cpu_model, $pkg) = ("unknown", "unknown");
        
        # Check cache first
        if (exists $cache_ref->{$entry}) {
            my $cached = $cache_ref->{$entry};
            $cpu_model = $cached->{model};
            $pkg = $cached->{package};
            _debug(__LINE__, "Using cached CPU info for $entry");
        } else {
            # Lookup CPU information
            
            # ----- Intel coretemp -----
            if ($entry =~ /^coretemp-isa-(\d+)/) {
                my $isa_id = $1;
                
                # Find matching hwmon device
                for my $hwmon (glob "/sys/class/hwmon/hwmon*") {
                    my $name = read_sysfs("$hwmon/name");
                    next unless $name eq 'coretemp';
                    
                    my $dev = readlink("$hwmon/device");
                    next unless $dev;
                    
                    # coretemp.0 → package 0
                    if ($dev =~ /\.([0-9]+)$/) {
                        $pkg = $1;
                        $cpu_model = _cpu_model_by_package($pkg);
                        _debug(__LINE__, "Found Intel CPU: $entry -> Package $pkg, Model: $cpu_model");
                        last;
                    }
                }
            }
            
            # ----- AMD k10temp -----
            elsif ($entry =~ /^k10temp-pci-(\w+)/) {
                my $pci_addr = $1;
                
                # Convert short PCI address to pattern
                # k10temp-pci-00c3 -> 0000:00:18.3
                my $pci_pattern;
                if ($pci_addr =~ /^([0-9a-f]{2})([0-9a-f]{2})$/i) {
                    # Short format like "00c3" -> "00:18" (bus:device)
                    my ($bus, $dev_func) = ($1, $2);
                    $pci_pattern = sprintf("%04x:%02x:%02x", 0, hex($bus), hex($dev_func));
                    _debug(__LINE__, "Converted PCI address $pci_addr to pattern $pci_pattern");
                }
                
                # Find matching hwmon device
                for my $hwmon (glob "/sys/class/hwmon/hwmon*") {
                    my $name = read_sysfs("$hwmon/name");
                    next unless $name eq 'k10temp';
                    
                    my $dev = readlink("$hwmon/device");
                    next unless $dev;
                    
                    if ($dev =~ /$pci_pattern/ || $dev =~ /$pci_addr/) {
                        # For AMD, package/node info might be in different location
                        # Try to determine from PCI device or use 0 as default
                        $pkg = 0;
                        
                        # Attempt to find package from CPU topology
                        if (opendir(my $dh, "/sys/devices/system/cpu")) {
                            my @cpus = grep { /^cpu\d+$/ } readdir($dh);
                            closedir($dh);
                            
                            foreach my $cpu (@cpus) {
                                my $cpu_pkg = read_sysfs("/sys/devices/system/cpu/$cpu/topology/physical_package_id");
                                if ($cpu_pkg ne "unknown" && $cpu_pkg =~ /^\d+$/) {
                                    $pkg = $cpu_pkg;
                                    last;
                                }
                            }
                        }
                        
                        $cpu_model = _cpu_model_by_package($pkg);
                        _debug(__LINE__, "Found AMD CPU: $entry -> Package $pkg, Model: $cpu_model");
                        last;
                    }
                }
            }
            
            # Cache the lookup result
            $cache_ref->{$entry} = {
                model => $cpu_model,
                package => $pkg
            };
            
            _debug(__LINE__, "CPU: $entry -> Package $pkg (Model: $cpu_model)");
        }
        
        # Add metadata directly to the data structure
        if (exists $sensors_data->{$entry}) {
            $sensors_data->{$entry}->{cpu_model} = $cpu_model;
            $sensors_data->{$entry}->{cpu_package} = $pkg;
            _debug(__LINE__, "Enhanced $entry with CPU info");
        }
    }
    
    # Re-encode as pretty JSON
    my $enhanced_json = JSON->new->pretty->canonical->encode($sensors_data);
    
    return $enhanced_json;
}

# Helper function to get CPU model by package ID
sub _cpu_model_by_package {
    my ($pkg) = @_;
    
    # Try to read from /proc/cpuinfo
    if (open my $fh, '<', '/proc/cpuinfo') {
        my $current_pkg = -1;
        my $model_name = "unknown";
        
        while (my $line = <$fh>) {
            chomp $line;
            
            # Extract physical id
            if ($line =~ /^physical id\s+:\s+(\d+)/) {
                $current_pkg = $1;
            }
            
            # Extract model name
            if ($line =~ /^model name\s+:\s+(.+)$/) {
                $model_name = $1;
                $model_name =~ s/^\s+|\s+$//g;  # Trim whitespace
                
                # If this is the package we're looking for, return it
                if ($current_pkg == $pkg) {
                    close($fh);
                    return $model_name;
                }
            }
        }
        close($fh);
        
        # If we didn't find the specific package, return the last model found
        # (single socket systems won't have physical id)
        return $model_name if $model_name ne "unknown";
    }
    
    return "unknown";
}

# ============================================================================
# UPS Support
# ============================================================================

sub _collector_for_ups {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-ups-$device->{ups_name}";
    _debug(__LINE__, "UPS collector started");
    
    # Set up signal handlers for graceful shutdown
    my $shutdown = 0;
    _setup_collector_signals("ups-$device->{ups_name}", \$shutdown);
    
    while (!$shutdown) {
        my $upsData = _get_ups_status($device->{ups_name});

        # Write to ups state file (as string, not parsed JSON)
        eval {
            open my $ofh, '>', $ups_state_file or die "Failed to open $ups_state_file: $!";
            print $ofh $upsData;
            close $ofh;
            _debug(__LINE__, "Wrote ups data to $ups_state_file");
        };
        if ($@) {
            _debug(__LINE__, "Error writing ups data: $@");
        }

        sleep $config{intervals}{data_pull} unless $shutdown;
    }
    _debug(__LINE__, "UPS collector shutting down");
    exit 0;
}

sub _get_ups_status {
    my ($ups_name) = @_;

    # upsc upsname[@hostname[:port]]
    _debug(__LINE__, "Collecting UPS status for $ups_name");
    
    # Execute command and capture output
    my $output = `/usr/bin/upsc $ups_name 2>/dev/null`;
    
    unless (defined $output) {
        _debug(__LINE__, "Failed to execute upsc");
        return encode_json({ error => "Failed to execute upsc" });
    }

    # Check if we got any output
    unless (defined $output && length($output) > 0) {
        _debug(__LINE__, "No output from upsc for $ups_name");
        return encode_json({ error => "No data from UPS $ups_name" });
    }

    # Convert upsc output to nested hash structure
    my $ups_data = _parse_upsc_output($output);
    
    # Check if we got any parsed data
    unless (keys %$ups_data) {
        _debug(__LINE__, "No data received from upsc for $ups_name");
        return encode_json({ error => "No data from UPS $ups_name" });
    }
    
    # Wrap in UPS name structure
    my $result = {
        $ups_name => $ups_data
    };
    
    # Return as pretty JSON
    return JSON->new->pretty->canonical->encode($result);
}

sub _parse_upsc_output {
    my ($output) = @_;
    
    my $ups_data = {};
    
    _debug(__LINE__, "Parsing upsc output");

    eval {
        foreach my $line (split /\n/, $output) {
            # Skip empty lines and SSL init message
            next if $line =~ /^\s*$/;
            next if $line =~ /^Init SSL/;
            
            # Parse key-value pairs (format: "key: value")
            if ($line =~ /^([^:]+):\s*(.*)$/) {
                my ($key, $value) = ($1, $2);

                # Trim whitespace
                $key =~ s/^\s+|\s+$//g;
                $value =~ s/^\s+|\s+$//g;
                
                # Store as flat key-value pairs (no nesting)
                # Convert numeric values to numbers, keep strings as strings
                if ($value =~ /^-?\d+\.?\d*$/) {
                    $ups_data->{$key} = $value + 0;
                } else {
                    $ups_data->{$key} = $value;
                }
            }
        }
    };
    if ($@) {
        _debug(__LINE__, "Error parsing upsc output: $@");
    }
    
    _debug(__LINE__, "Completed parsing upsc output");

    return $ups_data;
}

# ============================================================================
# API calls
# ============================================================================

sub get_graphic_stats {
    #  todo name the process without overruling other processes
    _debug(__LINE__, "get_graphic_stats called");
    
    # Start PVE Mod
    _pve_mod_starter();
    
    # Find all device-specific stat files
    my $dh;
    unless (opendir($dh, $stats_dir)) {
        _debug(__LINE__, "Failed to open stats directory: $stats_dir: $!");
        return $last_snapshot;
    }
    
    my @stat_files = grep { /^stats-(card\d+|nvidia\d+)\.json$/ } readdir($dh);
    closedir($dh);
    
    unless (@stat_files) {
        _debug(__LINE__, "No device stat files found in $stats_dir");
        return $last_snapshot;
    }
    
    _debug(__LINE__, "Found " . scalar(@stat_files) . " device stat file(s): " . join(', ', @stat_files));
    
    # Check if any files have been modified
    my $newest_mtime = 0;
    my $files_changed = 0;
    
    foreach my $file (@stat_files) {
        my $filepath = "$stats_dir/$file";
        my @stat = stat($filepath);
        if (@stat && $stat[9] > $newest_mtime) {
            $newest_mtime = $stat[9];
        }
    }
    
    if ($newest_mtime == $last_mtime) {
        _debug(__LINE__, "No device files modified, returning cached snapshot");
        return $last_snapshot;
    }
    
    _debug(__LINE__, "Device files modified ($last_mtime -> $newest_mtime), reading and merging files");
    
    # Merge all device files
    my $merged = {
        Graphics => {
            Intel => {},
            NVIDIA => {}
        }
    };
    
    foreach my $file (@stat_files) {
        my $filepath = "$stats_dir/$file";
        
        _debug(__LINE__, "Reading device file: $filepath");
        
        eval {
            my $fh;
            unless (open($fh, '<', $filepath)) {
                _debug(__LINE__, "Failed to open $filepath: $!");
                return;
            }
            
            local $/;
            my $json = <$fh>;
            close($fh);
            
            _debug(__LINE__, "Read $file, JSON length: " . length($json) . " bytes");
            
            my $device_data = decode_json($json);
            
            # Determine device type from filename and merge accordingly
            my $device_type = ($file =~ /^stats-card/) ? 'Intel' : 'NVIDIA';
            
            # Merge this device's data into the main structure
            foreach my $node_name (keys %$device_data) {
                $merged->{Graphics}->{$device_type}->{$node_name} = $device_data->{$node_name};
                _debug(__LINE__, "Merged $device_type node '$node_name' from $file");
            }
        };
        if ($@) {
            _debug(__LINE__, "Failed to read/parse $filepath: $@");
        }
    }
    
    # Update cache
    $last_snapshot = $merged;
    $last_mtime = $newest_mtime;
    $last_get_graphic_stats_time = time();
    
    my $intel_count = scalar(keys %{$merged->{Graphics}->{Intel}});
    my $nvidia_count = scalar(keys %{$merged->{Graphics}->{NVIDIA}});
    _debug(__LINE__, "Successfully merged $intel_count Intel + $nvidia_count NVIDIA device node(s)");
    
    # Notify pve_mod_worker of activity
    _notify_pve_mod_worker();

    return $last_snapshot;
}

sub get_sensors_stats {
    _debug(__LINE__, "get_sensors_stats called");

    # Start PVE Mod
    _pve_mod_starter();

    unless (-f $sensors_state_file) {
        _debug(__LINE__, "Sensors state file does not exist: $sensors_state_file");
        return {};
    }

    my $sensors_data;
    eval {
        open my $fh, '<', $sensors_state_file or die "Failed to open $sensors_state_file: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        $sensors_data = $json;
        _debug(__LINE__, "Read sensors data, JSON length: " . length($json) . " bytes");
        _debug(__LINE__, "Read sensors data from $sensors_state_file");
    };
    if ($@) {
        _debug(__LINE__, "Failed to read/parse sensors data: $@");
        return {};
    }


    # Notify pve_mod_worker of activity
    _notify_pve_mod_worker();

    return $sensors_data;
}

sub get_ups_stats {
    _debug(__LINE__, "get_ups_stats called");

    # Start PVE Mod
    _pve_mod_starter();

    unless (-f $ups_state_file) {
        _debug(__LINE__, "UPS state file does not exist: $ups_state_file");
        return {};
    }

    my $ups_data;
    eval {
        open my $fh, '<', $ups_state_file or die "Failed to open $ups_state_file: $!";
        local $/;
        my $json = <$fh>;
        close($fh);
        $ups_data = $json;
        _debug(__LINE__, "Read UPS data, JSON length: " . length($json) . " bytes");
        _debug(__LINE__, "Read UPS data from $ups_state_file");
    };
    if ($@) {
        _debug(__LINE__, "Failed to read/parse UPS data: $@");
        return {};
    }

    # Notify pve_mod_worker of activity
    _notify_pve_mod_worker();

    return $ups_data;
}

sub get_pve_mod_version {
    return $VERSION;
}

# ============================================================================
# Main Collector
# ============================================================================

sub _start_collector {
    my ($collector_name, $collector_type, $collector_sub, $device) = @_;
    
    _debug(__LINE__, "Starting $collector_type collector: $collector_name");
    
    # Check if already running (in worker's hash)
    if (exists $collectors{$collector_name}) {
        my $pid = $collectors{$collector_name};
        if (kill(0, $pid)) {
            _debug(__LINE__, "$collector_type collector '$collector_name' already running with PID $pid");
            return $pid;
        } else {
            _debug(__LINE__, "Collector '$collector_name' PID $pid is stale, removing from registry");
            delete $collectors{$collector_name};
        }
    }
    
    # Start the collector
    my $pid = _start_child_collector($collector_name, $collector_sub, $device);
    
    unless ($pid) {
        _debug(__LINE__, "Failed to start $collector_type collector '$collector_name'");
        return undef;
    }
    
    # Register in worker's hash
    $collectors{$collector_name} = $pid;
    _debug(__LINE__, "Registered $collector_type collector '$collector_name' with PID $pid");
    
    # Verify it's alive
    sleep 0.1;
    if (kill(0, $pid)) {
        _debug(__LINE__, "Verified $collector_type collector '$collector_name' (PID $pid) is alive");
        return $pid;
    } else {
        _debug(__LINE__, "WARNING - $collector_type collector '$collector_name' (PID $pid) died immediately!");
        delete $collectors{$collector_name};
        return undef;
    }
}

sub _start_graphics_collectors {

    if (!$config{gpu}{intel_enabled} && !$config{gpu}{amd_enabled} && !$config{gpu}{nvidia_enabled}) {
        _debug(__LINE__, "No GPU types enabled, skipping collector startup");
        return;
    }
    else {
        _debug(__LINE__, "Starting graphics collectors");
    }
    
    # Generalized device collector management for future AMD/NVIDIA support
    my @all_devices;
    my @all_types;
    my @all_collector_subs;

    # Intel
    if ($config{gpu}{intel_enabled}) {
        _debug(__LINE__, "Intel GPU support enabled");
        _debug(__LINE__, "Checking for intel_gpu_top");
        
        return unless _check_executable('/usr/bin/intel_gpu_top', 'Intel');
        
        my @intel_devices = _get_intel_gpu_devices();
        unless (@intel_devices) {
            _debug(__LINE__, "No Intel GPU devices found");
        } else {
            _debug(__LINE__, "Found " . scalar(@intel_devices) . " Intel GPU device(s)");
            foreach my $device (@intel_devices) {
                push @all_devices, $device;
                push @all_types, 'intel';
                push @all_collector_subs, \&_collector_for_intel_device;
            }
        }
    }
    
    # AMD (future)
    if ($config{gpu}{amd_enabled}) {
        _debug(__LINE__, "AMD GPU support enabled");

        return unless _check_executable('/usr/bin/rocm-smi', 'AMD');

        my @amd_devices = _get_amd_gpu_devices();
        _debug(__LINE__, "Got " . scalar(@amd_devices) . " AMD devices");
        foreach my $device (@amd_devices) {
            push @all_devices, $device;
            push @all_types, 'amd';
            push @all_collector_subs, \&_collector_for_amd_device;
        }
    }

    _debug(__LINE__, "Finished detecting devices. Total collectors to manage: " . scalar(@all_devices));

    # Start each graphics collector using unified function (Intel/AMD only - NVIDIA handled separately)
    my $started_count = 0;
    
    # NVIDIA - single collector for all devices
    if ($config{gpu}{nvidia_enabled}) {
        _debug(__LINE__, "NVIDIA GPU support enabled");

        my @nvidia_devices = get_nvidia_gpu_devices();
        _debug(__LINE__, "Got " . scalar(@nvidia_devices) . " NVIDIA devices");
        
        if (@nvidia_devices) {
            # Start single collector for all NVIDIA GPUs
            my $pid = _start_collector('nvidia-all', 'nvidia', \&_collector_for_nvidia_devices, \@nvidia_devices);
            $started_count++ if $pid;
        }
    }
    for (my $i = 0; $i < @all_devices; $i++) {
        my $device = $all_devices[$i];
        my $type = $all_types[$i];
        my $collector_sub = $all_collector_subs[$i];
        my $device_name = $device->{card} // $device->{name} // "device$i";
        
        my $pid = _start_collector($device_name, $type, $collector_sub, $device);
        $started_count++ if $pid;
    }

    _debug(__LINE__, "Started/verified $started_count graphics collector(s) (Intel/AMD)");
}

sub _start_sensors_collector {
    _debug(__LINE__, "Starting temperature sensor collector");
    
    # Check if sensors is available (or debug mode with debug file)
    unless (_check_executable('/usr/bin/sensors', 'lm-sensors', $config{debug}{sensors_mode}, $config{debug}{sensors_output_file})) {
        _debug(__LINE__, "sensors not available and not in debug mode, skipping");
        return;
    }
    
    # Use unified collector startup
    _start_collector('sensors', 'sensors', \&_collector_for_temperature_sensors, { name => 'sensors' });
}

sub _start_ups_collector {

    if (!$config{ups}{enabled}) {
        _debug(__LINE__, "UPS support not enabled, skipping collector startup");
        return;
    }

    _debug(__LINE__, "Starting UPS collector");
    
    # Check if upsc is available
    unless (_check_executable('/usr/bin/upsc', 'UPS')) {
        _debug(__LINE__, "upsc not available, skipping UPS collector startup");
        return;
    }
    
    # Check if UPS is configured
    unless ($config{ups}{device_name}) {
        _debug(__LINE__, "No UPS configured, skipping collector startup");
        return;
    }
    
    # Use unified collector startup
    _start_collector('ups', 'ups', \&_collector_for_ups, { ups_name => $config{ups}{device_name} });
}

# ============================================================================
# PVE Mod Worker
# ============================================================================

sub _start_child_collector {
    my ($collector_name, $collector_sub, $device) = @_;
    
    _debug(__LINE__, "Starting child collector: $collector_name");
    
    my $pid = fork();
    unless (defined $pid) {
        _debug(__LINE__, "fork failed for $collector_name: $!");
        return undef;
    }
    
    if ($pid == 0) {
        # Child process
        $process_type = 'collector';
        _debug(__LINE__, "In child process for $collector_name");
        $0 = "collector-$collector_name";
        $collector_sub->($device);
        exit(0);
    }
    
    # Parent process (worker only)
    _debug(__LINE__, "Forked child PID $pid for $collector_name");
    return $pid;
}

sub _pve_mod_starter {
    # Check if pve_mod_worker is already running - if so, entire system is already up
    _debug(__LINE__, "Checking if pve_mod_worker is already running");
    if (_is_pve_mod_worker_running()) {
        _debug(__LINE__, "pve_mod_worker process already running, system is already started");
        return "pve_mod_worker process already running, system is already started";
    }
    _debug(__LINE__, "PVE mod worker is not running. PVE Mod will be started.");

    _pve_mod_hello();

    # Ensure directory exists
    _ensure_pve_mod_directory_exists();

    # Try to get the lock
    _debug(__LINE__, "Trying to acquire startup lock: $startup_lock");
    my $startup_fh = _acquire_exclusive_lock($startup_lock, 'startup lock');
    return unless $startup_fh;
    
    # SECOND CHECK (after lock) - verify nothing changed while waiting
    if (_is_pve_mod_worker_running()) {
        _debug(__LINE__, "Worker started by another process while we waited for lock");
        close($startup_fh);
        unlink($startup_lock);
        return "already running";
    }
    
    # Now we KNOW we're the only one starting things
    print $startup_fh "$$\n";
    $startup_fh->flush();
    _debug(__LINE__, "Wrote PID, $$, to startup lock");

    # Start pve mod worker (which will start all collectors)
    _pve_mod_worker();

    # Remove startup lock LAST
    unlink($startup_lock);
    _debug(__LINE__, "Released startup lock");
    
    _debug(__LINE__, "pve_mod_worker started successfully, returning");
}

sub _pve_mod_worker {
    _debug(__LINE__, "_pve_mod_worker called");
    
    # Check if worker is already running
    my $pve_mod_worker_fh = _acquire_exclusive_lock($pve_mod_worker_lock, 'pve_mod_worker lock');
    return unless $pve_mod_worker_fh;
    print $pve_mod_worker_fh "$$\n";
    close($pve_mod_worker_fh);
    
    _debug(__LINE__, "Forking new pve_mod_worker process");
    my $pve_mod_worker_pid = fork();
    
    unless (defined $pve_mod_worker_pid) {
        _debug(__LINE__, "Failed to fork pve_mod_worker process: $!");
        return;
    }
    
    if ($pve_mod_worker_pid == 0) {
        # Child process - run the pve_mod_worker
        $0 = "pve_mod_worker_controller";
        _debug(__LINE__, "Child process forked, calling _pve_mod_keep_alive");
        _pve_mod_keep_alive();
        exit(0);  # Should never reach here
    } else {
        # Parent process - write PID to lock file
        _debug(__LINE__, "Forked pve_mod_worker process with PID $pve_mod_worker_pid");
        
        if (open my $fh, '>', $pve_mod_worker_lock) {
            print $fh "$pve_mod_worker_pid\n";
            close $fh;
            _debug(__LINE__, "Wrote pve_mod_worker PID to lock file: $pve_mod_worker_lock");
        } else {
            _debug(__LINE__, "Failed to write pve_mod_worker lock file: $!");
            kill('TERM', $pve_mod_worker_pid);
        }
    }
    _debug(__LINE__, "pve_mod_worker process started successfully");
}

sub _notify_pve_mod_worker {
    _debug(__LINE__, "_notify_pve_mod_worker called");
    unless (-f $pve_mod_worker_lock) {
        _debug(__LINE__, "pve_mod_worker lock file does not exist");
        return;
    }

    _debug(__LINE__, "pve_mod_worker lock file exists, reading PID");
    if (open my $fh, '<', $pve_mod_worker_lock) {
        my $pid = <$fh>;
        close $fh;
        chomp $pid if defined $pid;
        if (defined $pid && $pid =~ /^(\d+)$/) {
            # Untaint by capturing in regex - $1 is now untainted
            my $clean_pid = $1;
            
            if (_is_process_alive($clean_pid)) {
                _debug(__LINE__, "Sending USR1 signal to pve_mod_worker PID $clean_pid");
                my $result = kill('USR1', $clean_pid);
                _debug(__LINE__, "Signal result: $result");
            } else {
                _debug(__LINE__, "pve_mod_worker process $clean_pid is not alive, removing stale lock");
                unlink($pve_mod_worker_lock);
            }
        } else {
            # Stale lock, remove it
            _debug(__LINE__, "pve_mod_worker lock is stale (PID: " . ($pid // 'undefined') . "), removing");
            unlink($pve_mod_worker_lock);
        }
    } else {
        _debug(__LINE__, "Failed to open pve_mod_worker lock file: $!");
    }
}

sub _pve_mod_keep_alive {
    $process_type = 'worker';
    _debug(__LINE__, "pve_mod_worker process started with PID $$");
    
    my $last_activity = time();
    
    # Set up signal handlers
    $SIG{USR1} = sub {
        $last_activity = time();
        _debug(__LINE__, "Activity ping received");
    };
    
    # SIGCHLD handler to prevent zombies and clean up collector registry
    $SIG{CHLD} = sub {
        while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            my $exit_status = $? >> 8;
            _debug(__LINE__, "Child process $pid exited with status $exit_status");
            
            # Find and remove from collector registry
            foreach my $name (keys %collectors) {
                if ($collectors{$name} == $pid) {
                    _debug(__LINE__, "Collector '$name' (PID $pid) exited, removing from registry");
                    delete $collectors{$name};
                    last;
                }
            }
        }
    };
    
    $SIG{TERM} = sub {
        _debug(__LINE__, "pve_mod_worker received SIGTERM, shutting down");
        _stop_child_collectors();
        unlink($pve_mod_worker_lock) if -f $pve_mod_worker_lock;
        exit(0);
    };
    $SIG{INT} = sub {
        _debug(__LINE__, "pve_mod_worker received SIGINT, shutting down");
        _stop_child_collectors();
        unlink($pve_mod_worker_lock) if -f $pve_mod_worker_lock;
        exit(0);
    };
    
    # Worker now starts all collectors (moved from _pve_mod_starter)
    _debug(__LINE__, "Worker starting all collectors");
    _start_sensors_collector();
    _start_graphics_collectors();
    _start_ups_collector();
    _debug(__LINE__, "All collectors started by worker");
    
    _debug(__LINE__, "Entering pve_mod_worker loop, timeout=$config{intervals}{collector_timeout}s");
    
    while (1) {
        _debug(__LINE__, "pve_mod_worker loop start: checking activity");
        
        my $idle_time = time() - $last_activity;
        
        _debug(__LINE__, "pve_mod_worker loop: idle_time=${idle_time}s, timeout=$config{intervals}{collector_timeout}s");
        
        if ($idle_time > $config{intervals}{collector_timeout}) {
            _debug(__LINE__, "Timeout reached, stopping collectors");
            _stop_child_collectors();
            _debug(__LINE__, "Collectors stopped, exiting pve_mod_worker");
            unlink($pve_mod_worker_lock) if -f $pve_mod_worker_lock;
            exit(0);
        }
        sleep(1);
    }
    
    # Should never reach here
    _debug(__LINE__, "pve_mod_worker loop exited unexpectedly!");
}

sub _is_pve_mod_worker_running {
    return -f $pve_mod_worker_lock;
}

sub _stop_child_collectors {
    _debug(__LINE__, "Stopping all collectors");
    
    # Get PIDs from worker's collector registry
    my @pids = values %collectors;
    
    if (@pids) {
        _debug(__LINE__, "Sending SIGTERM to " . scalar(@pids) . " collector process(es)");
        foreach my $pid (@pids) {
            if (kill(0, $pid)) {
                kill('TERM', $pid);
                _debug(__LINE__, "Sent SIGTERM to collector PID $pid");
            }
        }
        
        # Wait up to 2 seconds for graceful shutdown
        my $timeout = 2;
        my $start = time();
        while (time() - $start < $timeout) {
            my $any_alive = 0;
            foreach my $pid (@pids) {
                if (kill(0, $pid)) {
                    $any_alive = 1;
                    last;
                }
            }
            last unless $any_alive;
            select(undef, undef, undef, 0.1);
        }
        
        # Force kill any survivors
        foreach my $pid (@pids) {
            if (kill(0, $pid)) {
                _debug(__LINE__, "Force killing collector process $pid");
                kill('KILL', $pid);
            }
        }
    }
    
    # Clear collector registry
    %collectors = ();
    _debug(__LINE__, "Cleared collector registry");
    
    # Remove state files
    if (-f $state_file) {
        unlink $state_file or _debug(__LINE__, "Failed to remove $state_file: $!");
    }
    
    # Remove pve mod worker directory and all files if it exists
    if (-d $pve_mod_working_dir) {
        remove_tree($pve_mod_working_dir, { error => \my $err });
        _debug(__LINE__, "Cleanup errors: @$err") if @$err;
    }

    _debug(__LINE__, "Cleanup complete");
}

END { 
    if ($process_type eq 'worker') {
        _debug(__LINE__, "PVE Mod Worker END block: cleaning up");
        _stop_child_collectors();
    } elsif ($process_type eq 'collector') {
        _debug(__LINE__, "Collector ($0) END block: no cleanup needed");
        # Collectors just exit, no cleanup needed
    } else {
        _debug(__LINE__, "Main process END block: no cleanup needed");
        # Main pveproxy process doesn't cleanup
    }
}

1;
