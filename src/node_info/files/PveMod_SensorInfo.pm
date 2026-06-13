package PVE::API2::PVEMod_SensorInfo;

use strict;
use warnings;

use PVE::PVEMod::Config         qw(%config $VERSION $stats_dir $sensors_state_file $ups_state_file);
use PVE::PVEMod::Utils          qw(debug safe_read_json);
use PVE::PVEMod::ProcessManager qw(pve_mod_starter notify_pve_mod_worker);
use PVE::PVEMod::Collector::SystemInformation qw(get_system_information_data);

# Per-endpoint state caches (module-level, reset on worker restart)
my $graphics_cache     = { data => {},        mtime => 0 };
my $sensors_cache      = { data => '{}',       mtime => 0 };
my $ups_cache          = { data => '{}',       mtime => 0 };
my $system_info_cache  = undef;


# ============================================================================
# Internal helpers
# ============================================================================

sub _read_state_file_cached {
    my ($files, $cache_ref, $reader, $empty_fallback) = @_;

    # Normalize scalar path to single-element arrayref
    my @filepaths = ref($files) eq 'ARRAY' ? @$files : ($files);

    # Find newest mtime across all files
    my $newest_mtime = 0;
    my $any_exist    = 0;
    foreach my $fp (@filepaths) {
        my @st = stat($fp);
        if (@st) {
            $any_exist    = 1;
            $newest_mtime = $st[9] if $st[9] > $newest_mtime;
        }
    }

    unless ($any_exist) {
        debug(__LINE__, "No state files exist: " . join(', ', @filepaths));
        return $cache_ref->{data} // $empty_fallback;
    }

    if ($newest_mtime == $cache_ref->{mtime} && defined $cache_ref->{data}) {
        debug(__LINE__, "State files unchanged, returning cached data");
        return $cache_ref->{data};
    }

    my $data;
    if (ref($reader) eq 'CODE') {
        $data = $reader->(\@filepaths);
    } else {
        $data = safe_read_json($filepaths[0], $reader);
    }

    if (!defined $data) {
        debug(__LINE__, "Failed to read state file(s): " . join(', ', @filepaths));
        return $cache_ref->{data} // $empty_fallback;
    }

    $cache_ref->{data}  = $data;
    $cache_ref->{mtime} = $newest_mtime;
    return $cache_ref->{data};
}

sub _merge_graphics_files {
    my ($filepaths) = @_;

    my $merged = {
        Graphics => {
            Intel  => {},
            NVIDIA => {},
            AMD    => {},
        }
    };

    foreach my $filepath (@$filepaths) {
        my ($file) = $filepath =~ m{([^/]+)$};
        debug(__LINE__, "Reading device file: $filepath");

        my $device_data = safe_read_json($filepath, 0);
        if (!$device_data) {
            debug(__LINE__, "Failed to read/parse $filepath");
            next;
        }

        my $device_type = ($file =~ /^stats-card/)   ? 'Intel'
                        : ($file =~ /^stats-nvidia/) ? 'NVIDIA'
                        :                              'AMD';

        foreach my $node_name (keys %$device_data) {
            $merged->{Graphics}->{$device_type}->{$node_name} = $device_data->{$node_name};
            debug(__LINE__, "Merged $device_type node '$node_name' from $file");
        }
    }

    return $merged;
}

sub _load_graphics_data {
    # Build filename patterns for enabled GPU types
    my @patterns;
    push @patterns, 'card\d+'   if $config{gpu}{intel_enabled};
    push @patterns, 'nvidia\d+' if $config{gpu}{nvidia_enabled};
    push @patterns, 'amd\d+'    if $config{gpu}{amd_enabled};

    unless (@patterns) {
        debug(__LINE__, "No GPU types enabled in config");
        return $graphics_cache->{data};
    }

    my $pattern = join('|', @patterns);

    # Find device stat files for enabled GPU types
    my $dh;
    unless (opendir($dh, $stats_dir)) {
        debug(__LINE__, "Failed to open stats directory: $stats_dir: $!");
        return $graphics_cache->{data};
    }

    my @stat_files = grep { /^stats-(?:$pattern)\.json$/ } readdir($dh);
    closedir($dh);

    unless (@stat_files) {
        debug(__LINE__, "No device stat files found in $stats_dir");
        return $graphics_cache->{data};
    }

    debug(__LINE__, "Found " . scalar(@stat_files) . " device stat file(s): " . join(', ', @stat_files));

    my @filepaths = map { "$stats_dir/$_" } @stat_files;

    my $data = _read_state_file_cached(
        \@filepaths,
        $graphics_cache,
        \&_merge_graphics_files,
        { Graphics => { Intel => {}, NVIDIA => {}, AMD => {} } }
    );

    my $intel_count  = scalar(keys %{$data->{Graphics}{Intel}  // {}});
    my $nvidia_count = scalar(keys %{$data->{Graphics}{NVIDIA} // {}});
    my $amd_count    = scalar(keys %{$data->{Graphics}{AMD}    // {}});
    debug(__LINE__, "Returning $intel_count Intel + $nvidia_count NVIDIA + $amd_count AMD device node(s)");

    return $data;
}

# ============================================================================
# API calls
# ============================================================================

sub get_graphics_info {
    debug(__LINE__, "get_graphics_info called");
    if (!($config{gpu}{intel_enabled} || !$config{gpu}{nvidia_enabled} || !$config{gpu}{amd_enabled})) {
        debug(__LINE__, "GPU information collection is disabled");
        return { };
    }

    # Start PVE Mod
    pve_mod_starter();

    my $data = _load_graphics_data();

    # Notify pve_mod_worker of activity
    notify_pve_mod_worker();

    return $data;
}

sub get_sensors_info {
    debug(__LINE__, "get_sensors_info called");
    if (!$config{lm_sensors}{enabled}) {
        debug(__LINE__, "LM Sensors collection is disabled");
        return {};
    }

    # Start PVE Mod
    pve_mod_starter();

    my $data = _read_state_file_cached($sensors_state_file, $sensors_cache, 1, '{}');

    # Notify pve_mod_worker of activity
    notify_pve_mod_worker();

    return $data;
}

sub get_ups_info {
    debug(__LINE__, "get_ups_info called");
    if (!$config{ups}{enabled}) {
        debug(__LINE__, "UPS collection is disabled");
        return {};
    }

    # Start PVE Mod
    pve_mod_starter();

    my $data = _read_state_file_cached($ups_state_file, $ups_cache, 1, '{}');

    # Notify pve_mod_worker of activity
    notify_pve_mod_worker();

    return $data;
}

sub get_pve_mod_version {
    debug(__LINE__, "get_pve_mod_version called");
    
    # Notify pve_mod_worker of activity
    notify_pve_mod_worker();
    
    debug(__LINE__, "Returning version: $VERSION");

    return $VERSION;
}

sub get_system_information {
    debug(__LINE__, "get_system_information called");

    if (defined $system_info_cache) {
        debug(__LINE__, "Returning cached system information");
        return $system_info_cache;
    }

    $system_info_cache = get_system_information_data();

    return $system_info_cache;
}

1;
