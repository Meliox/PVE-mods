package PVE::PVEMods::Collector::Intel;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP;

use PVE::PVEMods::Config qw(%config $process_type $pve_mods_working_dir);
use PVE::PVEMods::Utils  qw(debug check_executable setup_collector_signals safe_write_json read_sysfs);
use PVE::PVEMods::Store  qw(update_intel_gpu_rrd);

our @EXPORT_OK = qw(
    get_intel_gpu_devices
    collector_for_intel_device
);

use constant INTEL_VENDOR_ID => '8086';

# Matches the stderr output intel_gpu_top produces when it lacks CAP_PERFMON.
my $PERMISSION_ERROR_RE = qr/Failed to initialize PMU|Permission denied/;

my $JSON_PARSER = JSON::PP->new->utf8;

# Safety cap for the live-pipe read buffer in _extract_intel_json_objects — stray
# non-JSON text on stdout must never be allowed to grow it without bound.
use constant MAX_INTEL_JSON_BUFFER => 1_048_576;  # 1 MiB

# ============================================================================
# Intel GPU — device discovery
# ============================================================================

# Resolve the PCI vendor ID (lowercase, e.g. "8086") from either a
# "vendor=XXXX" descriptor or a "DDDD:BB:DD.F" address looked up via sysfs.
sub _get_pci_vendor_id {
    my ($path) = @_;

    if ($path =~ /vendor=([0-9a-fA-F]{4})/) {
        return lc($1);
    }

    if ($path =~ m{^pci:([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.\d+)$}) {
        my $vendor = read_sysfs("/sys/bus/pci/devices/$1/vendor");
        $vendor =~ s/^0x//i;
        return lc($vendor);
    }

    return undef;
}

sub get_intel_gpu_devices {
    my @devices = ();
    my $fh;

    # Parse: "card0  Intel Alderlake_n (Gen12)  pci:vendor=8086,device=46D0,card=0"
    # or:    "card0  Intel Alderlake_n (Gen12)  pci:0000:00:02.0"

    if ($config{debug}{intel_mode} && -f $config{debug}{intel_devices_file}) {
        my $file = $config{debug}{intel_devices_file};
        debug(__LINE__, "Debug mode: reading Intel GPU devices from $file");
        unless (open $fh, '<', $file) {
            debug(__LINE__, "Failed to open debug file $file: $!");
            return @devices;
        }
    } else {
        debug(__LINE__, "Getting Intel GPU devices");
        unless (open $fh, '-|', 'intel_gpu_top -L 2>&1') {
            debug(__LINE__, "Failed to run intel_gpu_top -L: $!");
            return @devices;
        }
    }

    my @lines;
    while (<$fh>) {
        chomp;
        push @lines, $_;
        if (/^(card\d+)\s+(.+?)\s+(pci:[^\s]+)/) {
            my ($card, $name, $path) = ($1, $2, $3);
            my $vendor = _get_pci_vendor_id($path);
            if (!defined $vendor || $vendor ne INTEL_VENDOR_ID) {
                debug(__LINE__, "Skipping non-Intel device: $card ($path) vendor=" . ($vendor // 'unknown'));
                next;
            }
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

    if (!@devices && grep { /$PERMISSION_ERROR_RE/ } @lines) {
        warn "[node_info] Intel GPU monitoring: www-data cannot read GPU performance counters "
            . "(CAP_PERFMON missing on intel_gpu_top). Re-run pve-mods-configure to grant it.\n";
    }

    return @devices;
}

# ============================================================================
# Intel GPU — data parsing
# ============================================================================

# intel_gpu_top's -J output is a comma-separated, never-closed JSON array; pick
# a fixed engine class out of $engines by name, tolerating a "/<n>" instance suffix.
sub _pick_engine {
    my ($engines, $class) = @_;

    return $engines->{$class} if exists $engines->{$class};
    for my $key (sort keys %$engines) {
        return $engines->{$key} if $key =~ m{^\Q$class\E(?:/\d+)?$};
    }
    return {};
}

sub _parse_intel_gpu_json {
    my ($data) = @_;
    return unless ref $data eq 'HASH';

    my $engines = $data->{engines} // {};

    my $render  = _pick_engine($engines, 'Render/3D');
    my $blitter = _pick_engine($engines, 'Blitter');
    my $video   = _pick_engine($engines, 'Video');
    my $videnh  = _pick_engine($engines, 'VideoEnhance');

    return {
        frequency => {
            requested => ($data->{frequency}{requested} // 0) + 0.0,
            actual    => ($data->{frequency}{actual}    // 0) + 0.0,
            unit      => $data->{frequency}{unit} // "MHz",
        },
        interrupts => {
            count => ($data->{interrupts}{count} // 0) + 0.0,
            unit  => $data->{interrupts}{unit} // "irq/s",
        },
        rc6 => {
            value => ($data->{rc6}{value} // 0) + 0.0,
            unit  => $data->{rc6}{unit} // "%",
        },
        power => {
            GPU     => ($data->{power}{GPU}     // 0) + 0.0,
            Package => ($data->{power}{Package} // 0) + 0.0,
            unit    => $data->{power}{unit} // "W",
        },
        engines => {
            'Render/3D' => {
                busy => ($render->{busy} // 0) + 0.0,
                sema => ($render->{sema} // 0) + 0.0,
                wait => ($render->{wait} // 0) + 0.0,
                unit => "%",
            },
            Blitter => {
                busy => ($blitter->{busy} // 0) + 0.0,
                sema => ($blitter->{sema} // 0) + 0.0,
                wait => ($blitter->{wait} // 0) + 0.0,
                unit => "%",
            },
            Video => {
                busy => ($video->{busy} // 0) + 0.0,
                sema => ($video->{sema} // 0) + 0.0,
                wait => ($video->{wait} // 0) + 0.0,
                unit => "%",
            },
            VideoEnhance => {
                busy => ($videnh->{busy} // 0) + 0.0,
                sema => ($videnh->{sema} // 0) + 0.0,
                wait => ($videnh->{wait} // 0) + 0.0,
                unit => "%",
            },
        },
        clients => {},
    };
}

# Pulls complete JSON objects out of a buffer holding a prefix of the
# "[ {...}, {...}, " stream. Consumes the leading "[" only once (tracked via
# $started_ref) and strips separating commas between objects.
sub _extract_intel_json_objects {
    my ($buf_ref, $started_ref) = @_;
    my @objects;

    unless ($$started_ref) {
        return @objects unless $$buf_ref =~ s/^\s*\[\s*//;
        $$started_ref = 1;
    }

    while (1) {
        $$buf_ref =~ s/^\s*,?\s*//;

        if ($$buf_ref =~ /^\{/) {
            my ($data, $consumed);
            eval { ($data, $consumed) = $JSON_PARSER->decode_prefix($$buf_ref); };
            last if $@ || !defined $data;

            substr($$buf_ref, 0, $consumed, '');
            push @objects, $data;
            next;
        }

        # Resync past stray non-JSON text (e.g. a warning line mixed into stdout)
        # instead of stalling forever with unparseable bytes stuck at the front.
        next if $$buf_ref =~ s/^[^{]+(?=\{)//s;

        if (length($$buf_ref) > MAX_INTEL_JSON_BUFFER) {
            debug(__LINE__, "Intel GPU JSON buffer exceeded safety cap without a valid object; discarding");
            $$buf_ref = '';
        }
        last;
    }

    return @objects;
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
    my $device_state_file = "$pve_mods_working_dir/stats-$device->{card}.json";

    debug(__LINE__, "Collector started for device: $drm_dev, writing to $device_state_file");

    my $shutdown = 0;
    setup_collector_signals($device->{card}, \$shutdown, sub {
        kill 'TERM', $intel_gpu_top_pid
            if defined $intel_gpu_top_pid && $intel_gpu_top_pid > 0;
    });

    my $node_name = "node0";

    my $emit = sub {
        my ($stats) = @_;
        return unless $stats;

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
    };

    if ($config{debug}{intel_mode} && -f $config{debug}{intel_output_file}) {
        debug(__LINE__, "Debug mode: reading Intel GPU stats from $config{debug}{intel_output_file}");
        while (!$shutdown) {
            if (open my $fh, '<', $config{debug}{intel_output_file}) {
                local $/;
                my $buffer  = <$fh>;
                close $fh;

                my $started = 0;
                for my $data (_extract_intel_json_objects(\$buffer, \$started)) {
                    $emit->(_parse_intel_gpu_json($data));
                }
            } else {
                debug(__LINE__, "Failed to open debug file $config{debug}{intel_output_file}: $!");
            }
            sleep $config{intervals}{data_pull} unless $shutdown;
        }
    } else {
        debug(__LINE__, "About to open pipe to intel_gpu_top");
        my $intel_pull_interval = $config{intervals}{data_pull} * 1000;  # milliseconds
        $intel_gpu_top_pid = open(my $fh, '-|',
            "intel_gpu_top -d $drm_dev -J -s $intel_pull_interval 2>&1");

        unless (defined $intel_gpu_top_pid && $intel_gpu_top_pid > 0) {
            debug(__LINE__, "Failed to run intel_gpu_top for $drm_dev: $!");
            exit 1;
        }

        debug(__LINE__, "Pipe opened successfully, PID=$intel_gpu_top_pid");

        my $buffer  = '';
        my $started = 0;

        while (!$shutdown) {
            my $bytes_read = sysread($fh, my $chunk, 4096);
            last unless defined $bytes_read;
            last if $bytes_read == 0;  # EOF

            $buffer .= $chunk;

            if ($buffer =~ /$PERMISSION_ERROR_RE/) {
                warn "[node_info] Intel GPU monitoring: www-data cannot read GPU performance counters "
                    . "for $device->{card} (CAP_PERFMON missing on intel_gpu_top). Re-run pve-mods-configure to grant it.\n";
                last;
            }

            for my $data (_extract_intel_json_objects(\$buffer, \$started)) {
                $emit->(_parse_intel_gpu_json($data));
            }
        }

        close $fh;
    }

    debug(__LINE__, "Collector for $device->{card} shutting down");
    exit 0;
}

1;

