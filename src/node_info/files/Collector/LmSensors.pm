package PVE::PVEMod::Collector::LmSensors;

use strict;
use warnings;
use Exporter 'import';

use JSON;

use PVE::PVEMod::Config qw(%config $process_type $sensors_state_file);
use PVE::PVEMod::Utils  qw(debug check_executable setup_collector_signals read_sysfs);

our @EXPORT_OK = qw(
    collector_for_temperature_sensors
);

# ============================================================================
# Temperature Sensors — long-running collector
# ============================================================================

sub collector_for_temperature_sensors {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-temperature-sensors";
    my %cache;
    my $shutdown = 0;
    setup_collector_signals('temperature-sensors', \$shutdown);

    while (!$shutdown) {
        my $sensors_data = _get_temperature_sensors(\%cache);

        eval {
            open my $ofh, '>', $sensors_state_file
                or die "Failed to open $sensors_state_file: $!";
            print $ofh $sensors_data;
            close $ofh;
            debug(__LINE__, "Wrote temperature sensor data to $sensors_state_file");
        };
        if ($@) {
            debug(__LINE__, "Error writing temperature sensor data: $@");
        }

        sleep $config{intervals}{data_pull} unless $shutdown;
    }

    debug(__LINE__, "Temperature sensor collector shutting down");
    exit 0;
}

# ============================================================================
# Temperature Sensors — pipeline
# ============================================================================

sub _get_temperature_sensors {
    my ($cache_ref) = @_;

    my $sensors_output;

    if ($config{debug}{lm_sensors_mode} && -f $config{debug}{lm_sensors_output_file}) {
        debug(__LINE__, "Debug mode: reading lm-sensors data from $config{debug}{lm_sensors_output_file}");
        if (open my $fh, '<', $config{debug}{lm_sensors_output_file}) {
            local $/;
            $sensors_output = <$fh>;
            close $fh;
            debug(__LINE__, "Read lm-sensors data from debug file, length: "
                             . length($sensors_output) . " bytes");
        } else {
            debug(__LINE__, "Failed to open debug file $config{debug}{lm_sensors_output_file}: $!");
            $sensors_output = '{}';
        }
    } else {
        $sensors_output = `sensors -j 2>/dev/null | python3 -m json.tool`;
        debug(__LINE__, "Raw lm-sensors output collected from command");
    }

    debug(__LINE__, "Raw lm-sensors output collected");

    my $data = _sanitize_sensors($sensors_output);
    debug(__LINE__, "Sanitized lm-sensors output");

    $data = _get_drive_names($data, $cache_ref);
    debug(__LINE__, "Translated drive names in lm-sensors output");

    $data = _get_cpu_name($data, $cache_ref);
    debug(__LINE__, "Translated CPU names in lm-sensors output");

    # Wrap in top-level key
    my $sensors_json;
    eval { $sensors_json = decode_json($data); };
    if ($@) {
        debug(__LINE__, "Failed to parse final lm-sensors JSON: $@");
        return $data;
    }

    $data = JSON->new->pretty->encode({ "PVE MOD lm-sensors Enhanced" => $sensors_json });

    return $data;
}

# ============================================================================
# Sanitize raw lm-sensors JSON
# ============================================================================

sub _sanitize_sensors {
    my ($sensors_output) = @_;

    $sensors_output =~ s/ERROR:.+\s(\w+):\s(.+)/\"$1\": 0.000,/g;
    $sensors_output =~ s/ERROR:.+\s(\w+)!/\"$1\": 0.000,/g;
    $sensors_output =~ s/,\s*(})/$1/g;
    $sensors_output =~ s/\bNaN\b/null/g;

    # Fix duplicate SODIMM keys: "SODIMM":{"temp3_input":34.0} → "SODIMM3":{...}
    $sensors_output =~
        s/\"SODIMM\":\{\"temp(\d+)_input\"/\"SODIMM$1\":\{\"temp$1_input\"/g;

    return $sensors_output;
}

# ============================================================================
# Enrich lm-sensors data with drive device info
# ============================================================================

sub _get_drive_names {
    my ($sensors_output, $cache_ref) = @_;
    $cache_ref //= {};

    my $sensors_data;
    eval { $sensors_data = decode_json($sensors_output); };
    if ($@) {
        debug(__LINE__, "Failed to parse sensors JSON: $@");
        return $sensors_output;
    }

    my @entries = grep {
        /^drivetemp-scsi-/ || /^drivetemp-nvme-/ || /^nvme-pci-/
    } keys %{$sensors_data};

    debug(__LINE__, "Found " . scalar(@entries) . " drive entries in lm-sensors output");

    my @drive_names;

    foreach my $entry (@entries) {
        my ($dev_path, $model, $serial) = ("unknown", "unknown", "unknown");

        if (exists $cache_ref->{$entry}) {
            my $cached = $cache_ref->{$entry};
            $dev_path = $cached->{device_path};
            $model    = $cached->{model};
            $serial   = $cached->{serial};
            debug(__LINE__, "Using cached drive info for $entry");
        } else {
            # ----- SCSI/SATA -----
            if ($entry =~ /^drivetemp-scsi-(\d+)-(\d+)/) {
                my ($host, $id) = ($1, $2);
                my $scsi_path = "/sys/class/scsi_disk/$host:$id:0:0/device/block";

                if (opendir(my $sdh, $scsi_path)) {
                    my @devs = grep { /^sd/ } readdir($sdh);
                    closedir($sdh);
                    if (@devs) {
                        $dev_path = "/dev/$devs[0]";
                        $model    = read_sysfs("/sys/class/block/$devs[0]/device/model");
                        $serial   = read_sysfs("/sys/class/block/$devs[0]/device/serial");
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

                # Convert short PCI address (e.g. "0600") to pattern (e.g. "0000:06:00")
                my $pci_pattern;
                if ($pci_addr =~ /^([0-9a-f]{2})([0-9a-f]{2})$/i) {
                    my ($bus, $dev) = ($1, $2);
                    $pci_pattern = sprintf("%04x:%02x:%02x", 0, hex($bus), hex($dev));
                    debug(__LINE__, "Converted PCI address $pci_addr to pattern $pci_pattern");
                } else {
                    $pci_pattern = $pci_addr;
                }

                my $found    = 0;
                my $nvme_dir = "/sys/class/nvme";

                debug(__LINE__,
                    "Searching for NVMe devices in $nvme_dir matching PCI pattern $pci_pattern");

                if (opendir(my $ndh, $nvme_dir)) {
                    my @nvme_devs =
                        grep { /^nvme\d+$/ && -d "$nvme_dir/$_" } readdir($ndh);
                    closedir($ndh);

                    debug(__LINE__, "Found NVMe devices: " . join(", ", @nvme_devs));

                    foreach my $nvme_dev (@nvme_devs) {
                        my $device_link = readlink("$nvme_dir/$nvme_dev/device");
                        if ($device_link && $device_link =~ /$pci_pattern/) {
                            debug(__LINE__,
                                "NVMe device $nvme_dev matches PCI pattern $pci_pattern");
                            $dev_path = "/dev/${nvme_dev}n1";
                            $model    = read_sysfs("$nvme_dir/$nvme_dev/model");
                            $serial   = read_sysfs("$nvme_dir/$nvme_dev/serial");
                            $found    = 1;
                            debug(__LINE__,
                                "Found NVMe device via /sys/class/nvme: $dev_path");
                            last;
                        }
                        debug(__LINE__,
                            "NVMe device $nvme_dev did not match PCI pattern $pci_pattern");
                    }
                }

                # Fallback: scan /sys/class/block
                if (!$found && opendir(my $bdh, "/sys/class/block")) {
                    my @block_devs = grep { /^nvme\d+n\d+$/ } readdir($bdh);
                    closedir($bdh);

                    foreach my $block_dev (@block_devs) {
                        my $device_link =
                            readlink("/sys/class/block/$block_dev/device");
                        if ($device_link && $device_link =~ /$pci_pattern/) {
                            $dev_path = "/dev/$block_dev";
                            (my $nvme_ctrl = $block_dev) =~ s/n\d+$//;
                            $model  = read_sysfs("/sys/class/nvme/$nvme_ctrl/model");
                            $serial = read_sysfs("/sys/class/nvme/$nvme_ctrl/serial");
                            $found  = 1;
                            debug(__LINE__,
                                "Found NVMe device via /sys/class/block: $dev_path");
                            last;
                        }
                    }
                }

                unless ($found) {
                    debug(__LINE__,
                        "Could not find device for nvme-pci-$pci_addr (pattern: $pci_pattern)");
                }
            } else {
                next;
            }

            $cache_ref->{$entry} = {
                device_path => $dev_path,
                model       => $model,
                serial      => $serial,
            };

            debug(__LINE__, "Drive: $entry -> $dev_path (Model: $model, Serial: $serial)");
        }

        push @drive_names, [$entry, $dev_path, $model, $serial];
    }

    foreach my $drive_entry (@drive_names) {
        my ($original_name, $dev_path, $model, $serial) = @$drive_entry;
        if (exists $sensors_data->{$original_name}) {
            $sensors_data->{$original_name}->{device_path} = $dev_path;
            $sensors_data->{$original_name}->{model}       = $model;
            $sensors_data->{$original_name}->{serial}      = $serial;
            debug(__LINE__, "Enhanced $original_name with drive info");
        }
    }

    return JSON->new->pretty->canonical->encode($sensors_data);
}

# ============================================================================
# Enrich lm-sensors data with CPU model info
# ============================================================================

sub _get_cpu_name {
    my ($sensors_output, $cache_ref) = @_;
    $cache_ref //= {};

    my $sensors_data;
    eval { $sensors_data = decode_json($sensors_output); };
    if ($@) {
        debug(__LINE__, "Failed to parse sensors JSON: $@");
        return $sensors_output;
    }

    my @entries =
        grep { /^coretemp-isa-/ || /^k10temp-pci-/ } keys %{$sensors_data};

    debug(__LINE__, "Found " . scalar(@entries) . " CPU entries in sensors output");

    foreach my $entry (@entries) {
        my ($cpu_model, $pkg) = ("unknown", "unknown");

        if (exists $cache_ref->{$entry}) {
            my $cached = $cache_ref->{$entry};
            $cpu_model = $cached->{model};
            $pkg       = $cached->{package};
            debug(__LINE__, "Using cached CPU info for $entry");
        } else {
            # ----- Intel coretemp -----
            if ($entry =~ /^coretemp-isa-(\d+)/) {
                for my $hwmon (glob "/sys/class/hwmon/hwmon*") {
                    my $name = read_sysfs("$hwmon/name");
                    next unless $name eq 'coretemp';

                    my $dev = readlink("$hwmon/device");
                    next unless $dev;

                    if ($dev =~ /\.([0-9]+)$/) {
                        $pkg       = $1;
                        $cpu_model = _cpu_model_by_package($pkg);
                        debug(__LINE__,
                            "Found Intel CPU: $entry -> Package $pkg, Model: $cpu_model");
                        last;
                    }
                }
            }

            # ----- AMD k10temp -----
            elsif ($entry =~ /^k10temp-pci-(\w+)/) {
                my $pci_addr    = $1;
                my $pci_pattern = $pci_addr;

                if ($pci_addr =~ /^([0-9a-f]{2})([0-9a-f]{2})$/i) {
                    my ($bus, $dev_func) = ($1, $2);
                    $pci_pattern =
                        sprintf("%04x:%02x:%02x", 0, hex($bus), hex($dev_func));
                    debug(__LINE__,
                        "Converted PCI address $pci_addr to pattern $pci_pattern");
                }

                for my $hwmon (glob "/sys/class/hwmon/hwmon*") {
                    my $name = read_sysfs("$hwmon/name");
                    next unless $name eq 'k10temp';

                    my $dev = readlink("$hwmon/device");
                    next unless $dev;

                    if ($dev =~ /$pci_pattern/ || $dev =~ /$pci_addr/) {
                        $pkg = 0;

                        if (opendir(my $dh, "/sys/devices/system/cpu")) {
                            my @cpus = grep { /^cpu\d+$/ } readdir($dh);
                            closedir($dh);

                            foreach my $cpu (@cpus) {
                                my $cpu_pkg = read_sysfs(
                                    "/sys/devices/system/cpu/$cpu/topology/physical_package_id");
                                if ($cpu_pkg ne "unknown" && $cpu_pkg =~ /^\d+$/) {
                                    $pkg = $cpu_pkg;
                                    last;
                                }
                            }
                        }

                        $cpu_model = _cpu_model_by_package($pkg);
                        debug(__LINE__,
                            "Found AMD CPU: $entry -> Package $pkg, Model: $cpu_model");
                        last;
                    }
                }
            }

            $cache_ref->{$entry} = { model => $cpu_model, package => $pkg };
            debug(__LINE__, "CPU: $entry -> Package $pkg (Model: $cpu_model)");
        }

        if (exists $sensors_data->{$entry}) {
            $sensors_data->{$entry}->{cpu_model}   = $cpu_model;
            $sensors_data->{$entry}->{cpu_package} = $pkg;
            debug(__LINE__, "Enhanced $entry with CPU info");
        }
    }

    return JSON->new->pretty->canonical->encode($sensors_data);
}

# ============================================================================
# CPU model lookup helper
# ============================================================================

sub _cpu_model_by_package {
    my ($pkg) = @_;

    if (open my $fh, '<', '/proc/cpuinfo') {
        my $current_pkg = -1;
        my $model_name  = "unknown";

        while (my $line = <$fh>) {
            chomp $line;

            if ($line =~ /^physical id\s+:\s+(\d+)/) {
                $current_pkg = $1;
            }

            if ($line =~ /^model name\s+:\s+(.+)$/) {
                $model_name = $1;
                $model_name =~ s/^\s+|\s+$//g;

                if ($current_pkg == $pkg) {
                    close($fh);
                    return $model_name;
                }
            }
        }
        close($fh);

        return $model_name if $model_name ne "unknown";
    }

    return "unknown";
}

1;
