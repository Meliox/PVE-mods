package PVE::PVEMods::Config;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    %config
    $DEBUG_ENABLED $VERSION $process_type
    $pve_mods_working_dir $stats_dir $state_file
    $sensors_state_file $ups_state_file $storage_health_state_file
    $smart_snapshot_dir $smart_snapshot_file
    $pve_mods_worker_lock $startup_lock
    $RRD_SOCKET $RRD_BASE
);

# ============================================================================
# Debug / Version
# ============================================================================

our $DEBUG_ENABLED;  # derived from %config{debug}{mod_debug} after ini load, below
our $VERSION       = 'version-placeholder';

# ============================================================================
# Config paths
# ============================================================================

my $CONF_FILE = '/etc/pve-mods/pve-mods.conf';
my $CONFD_DIR = '/etc/pve-mods/conf.d';

# Runtime process-type tag — set to 'worker' or 'collector' after fork.
# Each forked child gets its own copy of this variable.
our $process_type = 'main';  # 'main', 'worker', or 'collector'

# ============================================================================
# Configuration
# ============================================================================

our %config = (
    gpu => {
        intel_enabled  => 0,
        amd_enabled    => 0,
        nvidia_enabled => 0,
        gpu_history    => 0,
    },
    debug => {
        mod_debug              => 0,
        log_enabled            => 0,
        log_file               => '/tmp/pve-mods-debug.log',
        lm_sensors_mode        => 0,
        lm_sensors_output_file => '/tmp/sensors-output.json',
        intel_mode             => 0,
        intel_devices_file     => '/tmp/intel-gpu-devices.txt',
        intel_output_file      => '/tmp/intel-gpu-top-output.txt',
        nvidia_mode            => 0,
        nvidia_devices_file    => '/tmp/nvidia-smi-devices.csv',
        nvidia_output_file     => '/tmp/nvidia-smi-output.csv',
        amd_mode               => 0,
        amd_devices_file       => '/tmp/amd-gpu-devices.json',
        ups_mode               => 0,
        ups_output_file        => '/tmp/ups-output.json',
        storage_health_mode    => 0,
        zpool_output_file      => '/tmp/zpool-status.txt',
        smartctl_output_file   => '/tmp/smartctl-output.json',
    },
    intervals => {
        data_pull         => 1,          # seconds between data pulls
        collector_timeout => 10,         # stop collectors after N seconds of inactivity
    },
    lm_sensors => {
        enabled               => 0,
        enable_cpu            => 0,
        cpu_temp_target       => 'Core',
        enable_ram_temp       => 0,
        enable_hdd_temp       => 0,
        enable_nvme_temp      => 0,
        enable_other_temp     => 0,
        enable_fan_speed      => 0,
        display_zero_speed_fans => 0,
    },
    ups => {
        enabled     => 0,
        device_name => 'ups@localhost',
    },
    storage_health => {
        enabled              => 0,
        smart_enabled        => 1,     # 0 = ZFS checks only
        life_warning_percent => 20,    # remaining SSD life at or below this is a warning
        life_critical_percent => 10,   # remaining SSD life at or below this is critical
        zfs_interval         => 15,    # seconds between 'zpool status' runs
        smart_interval       => 1800,  # seconds between SMART queries of an active drive
        smart_wake_disks     => 0,     # 1 = allow SMART queries to spin up sleeping drives
    },
    system_info => {
        enabled => 0,
        type    => 1,  # 1 = System (dmidecode -t 1), 2 = Baseboard/Motherboard (dmidecode -t 2)
        temp_unit => 'C',
        ignore_temp_below => 5,
    },
    paths => {
        working_dir => '/run/pveproxy/pve-mods',
    },
);

# ============================================================================
# Derived paths
# ============================================================================

our $pve_mods_working_dir = $config{paths}{working_dir};
our $stats_dir           = $pve_mods_working_dir;
our $state_file          = "$pve_mods_working_dir/stats.json";
our $sensors_state_file  = "$pve_mods_working_dir/sensors.json";
our $ups_state_file      = "$pve_mods_working_dir/ups.json";
our $storage_health_state_file = "$pve_mods_working_dir/storage_health.json";

# SMART needs root, so a systemd service (outside pveproxy) queries the drives
# and publishes its results here for the unprivileged collector to read.
our $smart_snapshot_dir  = '/run/pve-mods-smart';
our $smart_snapshot_file = "$smart_snapshot_dir/smart.json";
our $pve_mods_worker_lock = "$pve_mods_working_dir/pve_mods_worker.lock";
our $startup_lock        = "$pve_mods_working_dir/startup.lock";

# ============================================================================
# RRD paths
# ============================================================================

our $RRD_SOCKET = '/var/run/rrdcached.sock';
our $RRD_BASE   = '/var/lib/rrdcached/db/pve-mods-gpu';

# ============================================================================
# Load configuration from /etc/pve-mods/pve-mods.conf (INI format).
# Merges file values into %config, overriding compiled-in defaults.
# Safe to call multiple times; silently skips missing file or unknown keys.
# ============================================================================

sub _load_ini_file {
    my ($path) = @_;
    return unless defined $path && -f $path;

    open my $fh, '<', $path or return;
    my $section = '';

    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/#.*//;           # strip inline comments
        $line =~ s/^\s+|\s+$//g;   # trim whitespace
        next unless length $line;

        if ($line =~ /^\[([^\]]+)\]$/) {
            $section = $1;
            next;
        }

        if ($line =~ /^([^=]+)=(.*)$/) {
            my ($key, $val) = ($1, $2);
            $key =~ s/^\s+|\s+$//g;
            $val =~ s/^\s+|\s+$//g;

            if ($section eq 'gpu' && exists $config{gpu}{$key}) {
                $config{gpu}{$key} = $val;
            }
            elsif ($section eq 'lm_sensors' && exists $config{lm_sensors}{$key}) {
                $config{lm_sensors}{$key} = $val;
            }
            elsif ($section eq 'ups' && exists $config{ups}{$key}) {
                $config{ups}{$key} = $val;
            }
            elsif ($section eq 'storage_health' && exists $config{storage_health}{$key}) {
                $config{storage_health}{$key} = $val;
            }
            elsif ($section eq 'system_info' && exists $config{system_info}{$key}) {
                $config{system_info}{$key} = $val;
            }
            elsif ($section eq 'debug' && exists $config{debug}{$key}) {
                $config{debug}{$key} = $val;
            }
        }
    }
    close $fh;
}

_load_ini_file($CONF_FILE);
_load_ini_file($_) for glob("$CONFD_DIR/*.conf");

$DEBUG_ENABLED = $config{debug}{mod_debug};

1;
