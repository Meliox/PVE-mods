package PVE::PVEMods::Collector::Amd;

use strict;
use warnings;
use POSIX ();
use Cwd qw(abs_path);
use JSON::PP qw(decode_json);
use Exporter 'import';

use PVE::PVEMods::Config qw(%config $process_type $pve_mods_working_dir);
use PVE::PVEMods::Utils qw(debug setup_collector_signals safe_write_json);
use PVE::PVEMods::Store qw(gpu_history_id update_amd_gpu_rrd);

our @EXPORT_OK = qw(get_amd_gpu_devices collector_for_amd_device);
my %read_errors;
my %value_errors;

sub _read {
    my ($path) = @_;
    return undef unless -e $path;
    my $value;
    if (open my $fh, '<', $path) {
        $value = <$fh>;
        close $fh;
    }
    if (!defined $value) {
        warn "AMD GPU: cannot read $path: $!\n" unless $read_errors{$path}++;
        return undef;
    }
    delete $read_errors{$path};
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _number {
    my ($path, $scale, $maximum, $signed) = @_;
    my $value = _read($path);
    return undef unless defined $value;
    if ($value !~ /\A-?\d+(?:\.\d+)?\z/ || length($value) > 20
        || abs($value) > 9007199254740991 || (!$signed && $value < 0)
        || (defined $maximum && $value > $maximum)) {
        warn "AMD GPU: invalid sensor value in $path\n" unless $value_errors{$path}++;
        return undef;
    }
    delete $value_errors{$path};
    return $value / ($scale || 1);
}

sub get_amd_gpu_devices {
    my ($drm_root) = @_;
    $drm_root //= '/sys/class/drm';
    if ($config{debug}{amd_mode}) {
        my $file = $config{debug}{amd_devices_file};
        open my $fh, '<', $file or die "AMD GPU: cannot open debug fixture $file: $!\n";
        local $/;
        my $devices = decode_json(<$fh>);
        close $fh;
        die "AMD GPU: debug fixture must be a device array\n" unless ref($devices) eq 'ARRAY';
        for my $device (@$devices) {
            die "AMD GPU: invalid debug device\n"
                unless ref($device) eq 'HASH' && ($device->{card} // '') =~ /^amd\d+$/
                && ($device->{sysfs_path} // '') =~ m{^/[a-zA-Z0-9_:./-]+$}
                && ($device->{history_id} // '') =~ /^[a-zA-Z0-9]+$/
                && defined $device->{name} && !ref($device->{name});
            ($device->{card}) = $device->{card} =~ /^(amd\d+)$/;
            ($device->{history_id}) = $device->{history_id} =~ /^([a-zA-Z0-9]+)$/;
            ($device->{sysfs_path}) = $device->{sysfs_path} =~ m{^(/[a-zA-Z0-9_:./-]+)$};
        }
        return @$devices;
    }
    my (%seen, @devices);
    for my $path (sort glob("$drm_root/card[0-9]*")) {
        next unless $path =~ m{/card(\d+)$};
        my $index = $1;
        my $device_path = abs_path("$path/device");
        next unless defined $device_path;
        my $vendor = _read("$device_path/vendor");
        next unless defined $vendor && lc($vendor) eq '0x1002';
        my $driver = abs_path("$device_path/driver");
        next unless defined $driver && $driver =~ m{/amdgpu$};
        my ($pci) = $device_path =~ m{/([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])$};
        next unless defined $pci && !$seen{$pci}++;
        my $product = _read("$device_path/product_name");
        my $device_id = _read("$device_path/device") // 'unknown';
        push @devices, {
            card => "amd$index",
            name => $product || "AMD GPU ($device_id)",
            pci_address => lc($pci),
            drm_path => "/dev/dri/card$index",
            sysfs_path => $device_path,
            history_id => gpu_history_id($pci, "amd$index"),
        };
    }
    debug(__LINE__, "Detected " . scalar(@devices) . " AMD GPU(s) bound to amdgpu");
    return @devices;
}

sub collect_amd_stats {
    my ($device) = @_;
    my $path = $device->{sysfs_path};
    my $stats = {};
    for my $entry (
        ['gpu_busy_percent', 'utilization', 'gpu', 1, 100],
        ['mem_busy_percent', 'utilization', 'memory', 1, 100],
        ['mem_info_vram_used', 'memory', 'used', 1048576],
        ['mem_info_vram_total', 'memory', 'total', 1048576],
        ['mem_info_gtt_used', 'gtt', 'used', 1048576],
        ['mem_info_gtt_total', 'gtt', 'total', 1048576],
    ) {
        my ($file, $group, $key, $scale, $maximum) = @$entry;
        my $value = _number("$path/$file", $scale, $maximum);
        $stats->{$group}{$key} = $value if defined $value;
    }
    $stats->{$_}{unit} = 'MiB' for grep { exists $stats->{$_} } qw(memory gtt);
    for my $hwmon (sort glob("$path/hwmon/hwmon*")) {
        next unless (_read("$hwmon/name") // '') eq 'amdgpu';
        for my $file (sort glob("$hwmon/*_input"), glob("$hwmon/power*_average")) {
            next unless $file =~ m{/((temp|freq|power|fan)(\d+))_(input|average)$};
            my ($sensor, $kind, $index, $measurement) = ($1, $2, $3, $4);
            # Prefer averaged power when both interfaces exist.
            next if $kind eq 'power' && $measurement eq 'input' && -e "$hwmon/${sensor}_average";
            my %scales = (temp => 1000, freq => 1000000, power => 1000000, fan => 1);
            my %units = (temp => 'C', freq => 'MHz', power => 'W', fan => 'RPM');
            my $value = _number($file, $scales{$kind}, undef, $kind eq 'temp');
            next unless defined $value;
            my $label = _read("$hwmon/${sensor}_label") || $sensor;
            $stats->{sensors}{$sensor} = { value => $value, label => $label, unit => $units{$kind} };
            if ($kind eq 'temp') {
                for my $limit (qw(max crit)) {
                    my $threshold = _number("$hwmon/${sensor}_$limit", 1000, undef, 1);
                    $stats->{sensors}{$sensor}{$limit} = $threshold if defined $threshold;
                }
                $stats->{temperature}{gpu} = $value if $index == 1;
            } elsif ($kind eq 'freq' && $index == 1) {
                $stats->{frequency} = { actual => $value, unit => 'MHz', label => $label };
            } elsif ($kind eq 'power' && $index == 1) {
                $stats->{power} = { draw => $value, unit => 'W', label => $label };
            } elsif ($kind eq 'fan' && $index == 1) {
                $stats->{fan} = { speed => $value, unit => 'RPM' };
            }
        }
    }
    return $stats;
}

sub collector_for_amd_device {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-gpu-amd-$device->{card}";
    my $shutdown = 0;
    setup_collector_signals($device->{card}, \$shutdown);
    my $file = "$pve_mods_working_dir/stats-$device->{card}.json";
    while (!$shutdown) {
        my $driver = abs_path("$device->{sysfs_path}/driver");
        my $present = -d $device->{sysfs_path}
            && ($config{debug}{amd_mode} || (defined $driver && $driver =~ m{/amdgpu$}));
        my $stats = $present ? collect_amd_stats($device) : {};
        my $data = { $device->{card} => {
            %$device, status => $present ? 'available' : 'unavailable', stats => $stats,
        } };
        unless (safe_write_json("$file.tmp", $data) && rename("$file.tmp", $file)) {
            warn "AMD GPU: failed to publish $file: $!\n";
            unlink("$file.tmp") or warn "AMD GPU: cannot remove $file.tmp: $!\n" if -f "$file.tmp";
            POSIX::_exit(1);
        }
        update_amd_gpu_rrd($device->{history_id}, $stats);
        unless ($present) {
            warn "AMD GPU: $device->{card} disappeared; readings are unavailable\n";
            last;
        }
        sleep $config{intervals}{data_pull} unless $shutdown;
    }
    debug(__LINE__, "AMD GPU collector $device->{card} stopped");
    POSIX::_exit(0);
}

1;
