package PVE::PVEMods::Collector::GpuNvidia;

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

use PVE::PVEMods::Config qw(%config $process_type $pve_mods_working_dir);
use PVE::PVEMods::Utils  qw(debug check_executable setup_collector_signals safe_write_json parse_csv_line);
use PVE::PVEMods::Store  qw(update_nvidia_gpu_rrd gpu_history_id);

our @EXPORT_OK = qw(
    get_nvidia_gpu_devices
    collector_for_nvidia_devices
);

# ============================================================================
# NVIDIA GPU — device discovery
# ============================================================================

sub _nvidia_device {
    my ($index, $name, $pci_bus_id) = @_;
    return {
        index      => $index,
        name       => $name,
        history_id => gpu_history_id($pci_bus_id, "nvidia$index"),
    };
}

sub get_nvidia_gpu_devices {
    my @devices = ();

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
                    push @devices, _nvidia_device(@values);
                    debug(__LINE__, "Found NVIDIA GPU device (debug): $values[1] (index: $values[0])");
                }
            }
            close $fh;
        } else {
            debug(__LINE__, "Failed to open debug file $config{debug}{nvidia_devices_file}: $!");
        }
    } else {
        if (open my $fh, '-|', 'nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv') {
            my $line_num = 0;
            while (<$fh>) {
                chomp;
                $line_num++;
                next if $line_num == 1 || /^\s*$/;
                my @values = parse_csv_line($_, 2);
                if (@values) {
                    push @devices, _nvidia_device(@values);
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

    # nvidia-smi prints "[N/A]" or "[Not Supported]" for sensors a GPU lacks;
    # those are left out rather than reported as 0.
    my @num = map { _numeric($_) } @values;
    return unless defined $num[0];

    my %stats = (
        index => $num[0],
        name  => $values[1],
    );
    my @groups = (
        [temperature => '°C',  gpu => $num[2]],
        [utilization => '%',   gpu => $num[3], memory => $num[4]],
        [memory      => 'MiB', used => $num[5], total => $num[6]],
        [power       => 'W',   draw => $num[7], limit => $num[8]],
        [fan         => '%',   speed => $num[9]],
    );
    for my $entry (@groups) {
        my ($name, $unit, %fields) = @$entry;
        my %present = map { $_ => $fields{$_} } grep { defined $fields{$_} } keys %fields;
        $stats{$name} = { %present, unit => $unit } if %present;
    }

    return \%stats;
}

sub _numeric {
    my ($value) = @_;
    return undef unless defined $value && $value =~ /^\s*(-?\d+(?:\.\d+)?)\s*$/;
    return $1 + 0.0;
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
        my $device_state_file = "$pve_mods_working_dir/stats-nvidia$device_index.json";

        my $device_name = $stats->{name};
        my $history_id  = "nvidia$device_index";
        foreach my $dev (@$devices) {
            if ($dev->{index} == $device_index) {
                $device_name = $dev->{name};
                $history_id  = $dev->{history_id} if $dev->{history_id};
                last;
            }
        }

        my $device_data = {
            $node_name => {
                name       => $device_name,
                index      => $device_index,
                history_id => $history_id,
                stats      => $stats,
            }
        };

        safe_write_json($device_state_file, $device_data);
        update_nvidia_gpu_rrd($history_id, $stats);
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
    POSIX::_exit(0);
}

1;
