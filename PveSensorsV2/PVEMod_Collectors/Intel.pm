package PVE::PVEMod::Collector::Intel;

use strict;
use warnings;
use Exporter 'import';

use PVE::PVEMod::Config qw(%config $process_type $pve_mod_working_dir);
use PVE::PVEMod::Utils  qw(debug check_executable setup_collector_signals safe_write_json);
use PVE::PVEMod::Store  qw(update_intel_gpu_rrd);

our @EXPORT_OK = qw(
    get_intel_gpu_devices
    collector_for_intel_device
);

# ============================================================================
# Intel GPU — device discovery
# ============================================================================

sub get_intel_gpu_devices {
    my @devices = ();

    return @devices unless check_executable('/usr/bin/intel_gpu_top', 'Intel GPU');

    debug(__LINE__, "Getting Intel GPU devices");
    if (open my $fh, '-|', 'intel_gpu_top -L') {
        while (<$fh>) {
            chomp;
            # Parse: "card0  Intel Alderlake_n (Gen12)  pci:vendor=8086,device=46D0,card=0"
            # or:    "card0  Intel Alderlake_n (Gen12)  pci:0000:00:02.0"
            if (/^(card\d+)\s+(.+?)\s+(pci:[^\s]+)/) {
                my ($card, $name, $path) = ($1, $2, $3);
                push @devices, {
                    card     => $card,
                    name     => $name,
                    path     => $path,
                    drm_path => "/dev/dri/$card",
                };
                debug(__LINE__, "Found Intel device: $card -> $name ($path)");
            }
        }
        close $fh;
    } else {
        debug(__LINE__, "Failed to run intel_gpu_top -L: $!");
    }

    return @devices;
}

# ============================================================================
# Intel GPU — data parsing
# ============================================================================

sub _parse_intel_gpu_line {
    my ($line) = @_;

    # Expected format (whitespace-aligned columns):
    # Freq MHz      IRQ RC6     Power W             RCS             BCS             VCS            VECS
    # req  act       /s   %   gpu   pkg       %  se  wa       %  se  wa       %  se  wa       %  se  wa
    #   0    0        0   0  0.00  7.47    0.00   0   0    0.00   0   0    0.00   0   0    0.00   0   0

    $line =~ s/^\s+|\s+$//g;
    my @values = grep { $_ ne '' } split(/\s+/, $line);

    return unless @values >= 18;

    return {
        frequency => {
            requested => $values[0] + 0.0,
            actual    => $values[1] + 0.0,
            unit      => "MHz",
        },
        interrupts => {
            count => $values[2] + 0.0,
            unit  => "irq/s",
        },
        rc6 => {
            value => $values[3] + 0.0,
            unit  => "%",
        },
        power => {
            GPU     => $values[4] + 0.0,
            Package => $values[5] + 0.0,
            unit    => "W",
        },
        engines => {
            'Render/3D' => {
                busy => $values[6]  + 0.0,
                sema => $values[7]  + 0.0,
                wait => $values[8]  + 0.0,
                unit => "%",
            },
            Blitter => {
                busy => $values[9]  + 0.0,
                sema => $values[10] + 0.0,
                wait => $values[11] + 0.0,
                unit => "%",
            },
            Video => {
                busy => $values[12] + 0.0,
                sema => $values[13] + 0.0,
                wait => $values[14] + 0.0,
                unit => "%",
            },
            VideoEnhance => {
                busy => $values[15] + 0.0,
                sema => $values[16] + 0.0,
                wait => $values[17] + 0.0,
                unit => "%",
            },
        },
        clients => {},
    };
}

# ============================================================================
# Intel GPU — long-running collector
# ============================================================================

sub collector_for_intel_device {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-gpu-intel-$device->{card}";

    my $drm_dev          = "drm:/dev/dri/$device->{card}";
    my $intel_gpu_top_pid = undef;
    my $device_state_file = "$pve_mod_working_dir/stats-$device->{card}.json";

    debug(__LINE__, "Collector started for device: $drm_dev, writing to $device_state_file");

    my $shutdown = 0;
    setup_collector_signals($device->{card}, \$shutdown, sub {
        kill 'TERM', $intel_gpu_top_pid
            if defined $intel_gpu_top_pid && $intel_gpu_top_pid > 0;
    });

    debug(__LINE__, "About to open pipe to intel_gpu_top");
    my $intel_pull_interval = $config{intervals}{data_pull} * 1000;  # milliseconds
    $intel_gpu_top_pid = open(my $fh, '-|',
        "intel_gpu_top -d $drm_dev -s $intel_pull_interval -l 2>&1");

    unless (defined $intel_gpu_top_pid && $intel_gpu_top_pid > 0) {
        debug(__LINE__, "Failed to run intel_gpu_top for $drm_dev: $!");
        exit 1;
    }

    debug(__LINE__, "Pipe opened successfully, PID=$intel_gpu_top_pid");

    my $node_name = "node0";

    while (my $line = <$fh>) {
        last if $shutdown;
        chomp $line;

        next if $line =~ /MHz|IRQ|RC6|Power|RCS|BCS|VCS|VECS|req\s+act|^\s*$/;

        if ($line =~ /^\s*[\d\s\.]+$/) {
            my $stats = _parse_intel_gpu_line($line);

            if ($stats) {
                my $device_data = {
                    $node_name => {
                        name        => $device->{name},
                        device_path => $device->{path},
                        drm_path    => $device->{drm_path},
                        stats       => $stats,
                    }
                };

                safe_write_json($device_state_file, $device_data);
                update_intel_gpu_rrd($device->{card}, $stats);
            }
        }
    }

    close $fh;
    debug(__LINE__, "Collector for $device->{card} shutting down");
    exit 0;
}

1;
