package PVE::PVEMod::Config;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    %config
    $DEBUG_ENABLED $VERSION $process_type
    $pve_mod_working_dir $stats_dir $state_file
    $sensors_state_file $ups_state_file
    $pve_mod_worker_lock $startup_lock
    $RRD_SOCKET $RRD_BASE
);

# ============================================================================
# Debug / Version
# ============================================================================

our $DEBUG_ENABLED = 1;
our $VERSION       = '1.0';

# Runtime process-type tag — set to 'worker' or 'collector' after fork.
# Each forked child gets its own copy of this variable.
our $process_type = 'main';  # 'main', 'worker', or 'collector'

# ============================================================================
# Configuration
# ============================================================================

our %config = (
    gpu => {
        intel_enabled  => 1,
        amd_enabled    => 0,
        nvidia_enabled => 0,
    },
    debug => {
        log_enabled         => 0,
        log_file            => '/tmp/pve-mod-debug.log',
        nvidia_mode         => 1,
        nvidia_devices_file => '/tmp/nvidia-smi-devices.csv',
        nvidia_output_file  => '/tmp/nvidia-smi-output.csv',
        intel_mode          => 0,
        intel_devices_file  => '/tmp/intel-gpu-devices.json',
        amd_mode            => 0,
        amd_devices_file    => '/tmp/amd-gpu-devices.json',
        ups_mode            => 0,
        ups_output_file     => '/tmp/ups-output.json',
        lm_sensors_mode        => 0,
        lm_sensors_output_file => '/tmp/sensors-output.json',
    },
    intervals => {
        data_pull         => 1,          # seconds between data pulls
        collector_timeout => 10,         # stop collectors after N seconds of inactivity
    },
    lm_sensors => {
        enabled => 1,
    },
    ups => {
        enabled     => 1,
        device_name => 'ups@192.168.3.2',
    },
    paths => {
        working_dir => '/run/pveproxy/pve-mod',
    },
);

# ============================================================================
# Derived paths
# ============================================================================

our $pve_mod_working_dir = $config{paths}{working_dir};
our $stats_dir           = $pve_mod_working_dir;
our $state_file          = "$pve_mod_working_dir/stats.json";
our $sensors_state_file  = "$pve_mod_working_dir/sensors.json";
our $ups_state_file      = "$pve_mod_working_dir/ups.json";
our $pve_mod_worker_lock = "$pve_mod_working_dir/pve_mod_worker.lock";
our $startup_lock        = "$pve_mod_working_dir/startup.lock";

# ============================================================================
# RRD paths
# ============================================================================

our $RRD_SOCKET = '/var/run/rrdcached.sock';
our $RRD_BASE   = '/var/lib/rrdcached/db/pve-mod-gpu';

1;
