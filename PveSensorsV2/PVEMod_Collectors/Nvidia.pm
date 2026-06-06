package PVE::PVEMod::Collector::Nvidia;

use strict;
use warnings;
use Exporter 'import';

use PVE::PVEMod::Config qw(%config $process_type $pve_mod_working_dir);
use PVE::PVEMod::Utils  qw(debug check_executable setup_collector_signals safe_write_json parse_csv_line);
use PVE::PVEMod::Store  qw(update_nvidia_gpu_rrd);

our @EXPORT_OK = qw(
    get_nvidia_gpu_devices
    collector_for_nvidia_devices
);

# ============================================================================
# NVIDIA GPU — device discovery
# ============================================================================

sub get_nvidia_gpu_devices {
    my @devices = ();

    unless (check_executable('/usr/bin/nvidia-smi', 'NVIDIA',
                              $config{debug}{nvidia_mode},
                              $config{debug}{nvidia_devices_file})) {
        return @devices;
    }

    if ($config{debug}{nvidia_mode} && -f $config{debug}{nvidia_devices_file}) {
        debug(__LINE__, "Debug mode: reading NVIDIA GPU devices from $config{debug}{nvidia_devices_file}");
        if (open my $fh, '<', $config{debug}{nvidia_devices_file}) {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                next if $line_num == 1 || /^\s*$/;
                my @values = parse_csv_line($_, 2);
                if (@values) {
                    push @devices, { index => $values[0], name => $values[1] };
                    debug(__LINE__, "Found NVIDIA GPU device (debug): $values[1] (index: $values[0])");
                }
            }
            close $fh;
        } else {
            debug(__LINE__, "Failed to open debug file $config{debug}{nvidia_devices_file}: $!");
        }
    } else {
        if (open my $fh, '-|', 'nvidia-smi --query-gpu=index,name --format=csv') {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                next if $line_num == 1 || /^\s*$/;
                my @values = parse_csv_line($_, 2);
                if (@values) {
                    push @devices, { index => $values[0], name => $values[1] };
                    debug(__LINE__, "Found NVIDIA GPU device: $values[1] (index: $values[0])");
                }
            }
            close $fh;
        }
    }

    return @devices;
}

# ============================================================================
# NVIDIA GPU — data parsing
# ============================================================================

sub _parse_nvidia_gpu_line {
    my ($line) = @_;

    # Expected CSV format:
    # index, name, temperature.gpu, utilization.gpu, utilization.memory,
    # memory.used, memory.total, power.draw, power.limit, fan.speed

    my @values = parse_csv_line($line, 10);
    return unless @values;

    return {
        index => $values[0] + 0,
        name  => $values[1],
        temperature => {
            gpu  => $values[2] + 0.0,
            unit => "°C",
        },
        utilization => {
            gpu    => $values[3] + 0.0,
            memory => $values[4] + 0.0,
            unit   => "%",
        },
        memory => {
            used  => $values[5] + 0.0,
            total => $values[6] + 0.0,
            unit  => "MiB",
        },
        power => {
            draw  => $values[7] + 0.0,
            limit => $values[8] + 0.0,
            unit  => "W",
        },
        fan => {
            speed => $values[9] + 0.0,
            unit  => "%",
        },
    };
}

# ============================================================================
# NVIDIA GPU — stat collection and write
# ============================================================================

sub _get_and_write_nvidia_stats {
    my ($devices) = @_;
    my @all_stats;

    if ($config{debug}{nvidia_mode} && -f $config{debug}{nvidia_output_file}) {
        debug(__LINE__, "Debug mode: reading NVIDIA GPU stats from $config{debug}{nvidia_output_file}");
        if (open my $fh, '<', $config{debug}{nvidia_output_file}) {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                next if $line_num == 1 || /^\s*$/;
                my $stats = _parse_nvidia_gpu_line($_);
                push @all_stats, $stats if $stats;
            }
            close $fh;
        } else {
            debug(__LINE__, "Failed to open debug file $config{debug}{nvidia_output_file}: $!");
        }
    } else {
        unless (check_executable('/usr/bin/nvidia-smi', 'NVIDIA')) {
            debug(__LINE__, "nvidia-smi not available, cannot collect stats");
            return 0;
        }

        my $query = 'index,name,temperature.gpu,utilization.gpu,utilization.memory,'
                  . 'memory.used,memory.total,power.draw,power.limit,fan.speed';
        my $cmd   = "nvidia-smi --query-gpu=$query --format=csv,nounits";

        if (open my $fh, '-|', $cmd) {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                next if $line_num == 1 || /^\s*$/;
                my $stats = _parse_nvidia_gpu_line($_);
                push @all_stats, $stats if $stats;
            }
            close $fh;
        }
    }

    foreach my $stats (@all_stats) {
        my $device_index = $stats->{index};

        unless ($device_index =~ /^(\d+)$/) {
            debug(__LINE__, "Invalid device index: $device_index, skipping");
            next;
        }
        $device_index = $1;  # untainted

        my $node_name         = "gpu$device_index";
        my $device_state_file = "$pve_mod_working_dir/stats-nvidia$device_index.json";

        my $device_name = $stats->{name};
        foreach my $dev (@$devices) {
            if ($dev->{index} == $device_index) {
                $device_name = $dev->{name};
                last;
            }
        }

        my $device_data = {
            $node_name => {
                name  => $device_name,
                index => $device_index,
                stats => $stats,
            }
        };

        safe_write_json($device_state_file, $device_data);
        update_nvidia_gpu_rrd($device_index, $stats);
    }

    unless (@all_stats) {
        debug(__LINE__, "No valid NVIDIA GPU stats collected");
    }

    return scalar(@all_stats);
}

# ============================================================================
# NVIDIA GPU — long-running collector (all devices in one process)
# ============================================================================

sub collector_for_nvidia_devices {
    my ($devices) = @_;
    $process_type = 'collector';
    $0 = "collector-gpu-nvidia-all";

    debug(__LINE__, "NVIDIA collector started for " . scalar(@$devices) . " GPU(s)");

    my $shutdown = 0;
    setup_collector_signals('nvidia-all', \$shutdown);

    while (!$shutdown) {
        _get_and_write_nvidia_stats($devices);
        sleep $config{intervals}{data_pull} unless $shutdown;
    }

    debug(__LINE__, "NVIDIA collector shutting down");
    exit 0;
}

1;
