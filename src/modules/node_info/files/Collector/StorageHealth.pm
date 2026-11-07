package PVE::PVEMods::Collector::StorageHealth;

use strict;
use warnings;
use Exporter 'import';

use JSON;
use POSIX ();

use PVE::PVEMods::Config qw(
    %config $process_type
    $storage_health_state_file $smart_snapshot_dir $smart_snapshot_file
);
use PVE::PVEMods::Utils qw(debug setup_collector_signals);

our @EXPORT_OK = qw(
    collector_for_storage_health
    smart_service_main
    parse_zpool_status
    parse_smartctl_json
    evaluate_storage_health
);

# Storage health: one summary row ("Volumes and drives") on the node Summary,
# either OK or the highest-priority problem. Details live in the ZFS/Disks views.
#
# Split in two so nothing in pveproxy needs root:
#
#   * collector_for_storage_health() runs inside the node_info worker as
#     www-data. It runs 'zpool status' (no privileges needed), reads the SMART
#     results published by the service below, evaluates both and writes a
#     compact summary for the API.
#   * smart_service_main() runs as root from pve-mods-storage-smart.service
#     (installed/removed by the node_info post-apply/post-revert hooks, only when
#     smartctl exists and smart_enabled=1). It runs smartctl read-only (no
#     self-tests, no power-state changes) and publishes the parsed results to
#     /run/pve-mods-smart/smart.json.
#
# Checks and severities:
#   critical  pool not ONLINE (with removed/faulted/unavailable/offline drives),
#             known data errors, SMART overall health failed, an attribute
#             currently FAILING_NOW (In_the_past is ignored), NVMe critical
#             warning flags, remaining life <= life_critical_percent
#   warning   resilver in progress, removed/faulted drive in an ONLINE pool (e.g.
#             cache), non-zero read/write/checksum counters, NVMe temperature
#             flag alone, remaining life <= life_warning_percent
#   info      scrub in progress, SMART data unavailable or out of date
# Remaining life comes from NVMe 'Percentage Used', recognized SATA SSD wear
# attributes (rotational drives are ignored) and SAS SSD endurance indicators.
#
# Sleeping drives: ATA/SCSI drives are queried with 'smartctl -n standby', so a
# drive in standby is skipped, never spun up (unless smart_wake_disks=1). It
# keeps its last result, flagged as sleeping, and is retried every 5 minutes; a
# drive never seen awake is reported as "not checked yet". A skipped check is
# never a failure. NVMe has no rotating media and is always queried. SAS/SCSI
# standby detection depends on the drive and controller and is unverified.
# Device discovery ('smartctl --scan-open' opens every drive) only runs when the
# set of block devices in /sys/block changes, including the first start after a
# boot. Drives smartctl cannot read (RAID controllers, USB bridges) are ignored.

use constant {
    SEV_INFO     => 1,
    SEV_WARNING  => 2,
    SEV_CRITICAL => 3,
};

my %SEVERITY_NAME = (1 => 'info', 2 => 'warning', 3 => 'critical');

# Lower rank is listed first among issues of equal severity.
my %RANK = (
    zfs_state    => 1,
    zfs_errors   => 2,
    smart_fail   => 3,
    smart_attr   => 4,
    nvme_warning => 5,
    life         => 6,
    zfs_member   => 7,
    zfs_counters => 8,
    zfs_resilver => 9,
    smart_info   => 10,
    zfs_scrub    => 11,
);

# SSD attributes whose normalized value is the remaining life in percent.
my %LIFE_ATTRIBUTES = map { $_ => 1 } qw(
    SSD_Life_Left
    Media_Wearout_Indicator
    Wear_Leveling_Count
    Percent_Lifetime_Remain
    Remaining_Lifetime_Perc
    Percent_Life_Remaining
);

my @NVME_WARNING_BITS = (
    [0x01, 'available spare below threshold', SEV_CRITICAL],
    [0x02, 'temperature outside limits',      SEV_WARNING],
    [0x04, 'reliability degraded',            SEV_CRITICAL],
    [0x08, 'media read-only',                 SEV_CRITICAL],
    [0x10, 'volatile memory backup failed',   SEV_CRITICAL],
    [0x20, 'persistent memory read-only',     SEV_CRITICAL],
);

my $ZPOOL_STATES = 'ONLINE|DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL|AVAIL|INUSE|SPLIT';

# ============================================================================
# Command helpers
# ============================================================================

sub _find_binary {
    my ($name) = @_;
    foreach my $dir (qw(/usr/sbin /sbin /usr/bin /bin)) {
        return "$dir/$name" if -x "$dir/$name";
    }
    return;
}

# Runs a command without a shell. Returns (stdout, exit_code), or an empty
# list if it could not be run or timed out.
sub _run_command {
    my ($timeout, @cmd) = @_;

    local $ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
    local $ENV{LC_ALL} = 'C';
    delete local @ENV{qw(IFS CDPATH ENV BASH_ENV)};

    my $pid = open(my $fh, '-|');
    return unless defined $pid;

    if (!$pid) {
        open(STDERR, '>', '/dev/null');
        { no warnings 'exec'; exec { $cmd[0] } @cmd; }
        POSIX::_exit(127);
    }

    my $out = '';
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        local $/;
        $out = <$fh> // '';
        alarm 0;
    };
    if ($@) {
        alarm 0;
        $timed_out = 1;
        kill 'KILL', $pid;
    }
    close($fh);
    my $status = $?;

    return if $timed_out || $status == -1;
    return ($out, $status >> 8);
}

sub _slurp {
    my ($path) = @_;
    return unless defined $path && -f $path;
    open(my $fh, '<', $path) or return;
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

sub _write_json_atomic {
    my ($path, $data, $mode) = @_;
    my ($safe) = $path =~ m{^([A-Za-z0-9_/.\-]+)$} or return 0;
    my $tmp = "$safe.tmp";

    my $ok = eval {
        open(my $fh, '>', $tmp) or die "open $tmp: $!";
        print $fh JSON->new->canonical->encode($data);
        close($fh) or die "close $tmp: $!";
        chmod($mode // 0644, $tmp);
        rename($tmp, $safe) or die "rename $tmp: $!";
        1;
    };
    unless ($ok) {
        debug(__LINE__, "Failed to write $safe: $@");
        unlink($tmp);
        return 0;
    }
    return 1;
}

sub _clamp_int {
    my ($value, $min, $max, $default) = @_;
    return $default unless defined $value && $value =~ /^\d+$/;
    return $min if $value < $min;
    return $max if $value > $max;
    return $value + 0;
}

# ============================================================================
# ZFS — 'zpool status' parser
# ============================================================================

# Returns an arrayref of pools:
#   { name, state, scan => { kind, state, percent, eta }, data_errors,
#     devices => [ { name, state, read, write, cksum, leaf, message } ] }
# 'devices' holds every vdev below the pool; 'leaf' marks physical devices.
sub parse_zpool_status {
    my ($text) = @_;
    return [] unless defined $text;
    $text =~ s/\r//g;

    my @pools;
    my ($pool, $mode);

    foreach my $line (split /\n/, $text) {
        if ($line =~ /^ {0,3}pool:\s*(\S+)/) {
            $pool = { name => $1, state => 'UNKNOWN', scan_text => '', data_errors => 0, devices => [] };
            push @pools, $pool;
            $mode = '';
            next;
        }
        next unless $pool;

        if ($line =~ /^ {0,3}state:\s*(\S+)/) { $pool->{state} = $1; $mode = ''; next; }
        if ($line =~ /^ {0,3}(?:status|action|see):/) { $mode = 'text'; next; }
        if ($line =~ /^ {0,3}scan:\s*(.*)$/) { $pool->{scan_text} = $1; $mode = 'scan'; next; }
        if ($line =~ /^ {0,3}config:/) { $mode = 'config'; next; }
        if ($line =~ /^ {0,3}errors:\s*(.*)$/) {
            $pool->{data_errors} = 1 unless $1 =~ /^No known data errors/i;
            $mode = 'errors';
            next;
        }

        if ($mode eq 'scan') {
            $pool->{scan_text} .= " $1" if $line =~ /^\s+(\S.*)$/;
        }
        elsif ($mode eq 'config') {
            my $dev = _parse_zpool_device_line($line);
            push @{ $pool->{devices} }, $dev if $dev;
        }
    }

    foreach my $p (@pools) {
        $p->{scan} = _parse_zpool_scan($p->{scan_text});
        _mark_leaf_devices($p);
    }

    return \@pools;
}

sub _parse_zpool_device_line {
    my ($line) = @_;

    return unless $line =~ /^\t( *)(\S+)\s+($ZPOOL_STATES)(?:\s+(\S+)\s+(\S+)\s+(\S+))?\s*(.*)$/;
    my ($indent, $name, $state, $read, $write, $cksum, $message) = ($1, $2, $3, $4, $5, $6, $7);

    return {
        name    => $name,
        state   => $state,
        depth   => int(length($indent) / 2),
        read    => $read  // '0',
        write   => $write // '0',
        cksum   => $cksum // '0',
        message => $message // '',
    };
}

# The first device line repeats the pool itself, so it is dropped. A device is
# a leaf when the next device is not nested below it.
sub _mark_leaf_devices {
    my ($pool) = @_;
    my $devices = $pool->{devices};

    shift @$devices if @$devices && $devices->[0]{name} eq $pool->{name};

    for my $i (0 .. $#$devices) {
        my $next = $devices->[$i + 1];
        $devices->[$i]{leaf} = (!$next || $next->{depth} <= $devices->[$i]{depth}) ? 1 : 0;
    }
}

sub _parse_zpool_scan {
    my ($text) = @_;
    my $scan = { kind => undef, state => 'none' };
    return $scan unless defined $text && length $text;

    my ($kind) = $text =~ /^\s*(scrub|resilver)/ or return $scan;
    $scan->{kind} = $kind;

    if ($text =~ /\bin progress\b/) {
        $scan->{state} = 'running';
    }
    elsif ($text =~ /^\s*(?:scrub|resilver)\s+paused\b/) {
        $scan->{state} = 'paused';
        return $scan;
    }
    else {
        $scan->{state} = 'done';
        return $scan;
    }

    $scan->{percent} = $1 + 0 if $text =~ /(\d+(?:\.\d+)?)%\s+done/;

    if ($text =~ /(?:(\d+)\s+days?\s+)?(\d+):(\d\d):(\d\d)\s+to go/) {
        $scan->{eta} = ($1 // 0) * 86400 + $2 * 3600 + $3 * 60 + $4;
    }
    elsif ($text =~ /\b((?:\d+d)?(?:\d+h)?(?:\d+m)?(?:\d+s)?)\s+to go/ && $1 =~ /\d/) {
        my $compact = $1;
        my $eta = 0;
        $eta += $1 * 86400 if $compact =~ /(\d+)d/;
        $eta += $1 * 3600  if $compact =~ /(\d+)h/;
        $eta += $1 * 60    if $compact =~ /(\d+)m/;
        $eta += $1         if $compact =~ /(\d+)s/;
        $scan->{eta} = $eta;
    }

    return $scan;
}

# ============================================================================
# SMART — 'smartctl -a -j' parser
# ============================================================================

# Accepts the JSON text (or decoded hash) of one smartctl run and returns a
# compact record, or undef if it is not smartctl output:
#   { name, dev, type, protocol, model, serial,
#     state            => ok | sleeping | unreadable,
#     passed           => 1 | 0 | undef,
#     failing_attrs    => [ names currently marked FAILING_NOW ],
#     critical_warning => NVMe critical-warning flags | undef,
#     life_remaining   => percent | undef }
sub parse_smartctl_json {
    my ($input) = @_;

    my $j = ref($input) ? $input : eval { decode_json($input) };
    return unless ref($j) eq 'HASH' && ref($j->{smartctl}) eq 'HASH';

    my $device = ref($j->{device}) eq 'HASH' ? $j->{device} : {};
    my $path   = $device->{name} // '';
    my ($name) = $path =~ m{([^/]+)$};
    return unless defined $name && length $name;

    my $rec = {
        name             => $name,
        dev              => $path,
        type             => $device->{type},
        protocol         => lc($device->{protocol} // ''),
        model            => $j->{model_name} // $j->{scsi_model_name},
        serial           => $j->{serial_number},
        state            => 'ok',
        passed           => undef,
        failing_attrs    => [],
        critical_warning => undef,
        life_remaining   => undef,
    };

    my $messages = join("\n", map { ref($_) eq 'HASH' ? ($_->{string} // '') : '' }
        @{ ref($j->{smartctl}{messages}) eq 'ARRAY' ? $j->{smartctl}{messages} : [] });

    # 'smartctl -n standby' skipped the drive because it is not spinning
    if ($messages =~ /Device is in [A-Z ]+ mode/) {
        $rec->{state} = 'sleeping';
        return $rec;
    }

    my $status = $j->{smart_status};
    $rec->{passed} = $status->{passed} ? 1 : 0
        if ref($status) eq 'HASH' && defined $status->{passed};

    my $seen_data = defined $rec->{passed};
    my $solid_state = !$j->{rotation_rate};

    my $table = ref($j->{ata_smart_attributes}) eq 'HASH' ? $j->{ata_smart_attributes}{table} : undef;
    if (ref($table) eq 'ARRAY') {
        $seen_data = 1;
        my @life;
        foreach my $attr (@$table) {
            next unless ref($attr) eq 'HASH';
            my $attr_name = $attr->{name} // '';
            push @{ $rec->{failing_attrs} }, $attr_name
                if ($attr->{when_failed} // '') eq 'FAILING_NOW';
            push @life, $attr->{value}
                if $solid_state && $LIFE_ATTRIBUTES{$attr_name}
                    && defined $attr->{value} && $attr->{value} =~ /^\d+$/;
        }
        if (@life) {
            my ($lowest) = sort { $a <=> $b } @life;
            $rec->{life_remaining} = $lowest > 100 ? 100 : $lowest;
        }
    }

    my $nvme = $j->{nvme_smart_health_information_log};
    if (ref($nvme) eq 'HASH') {
        $seen_data = 1;
        $rec->{critical_warning} = $nvme->{critical_warning} + 0
            if defined $nvme->{critical_warning} && $nvme->{critical_warning} =~ /^\d+$/;
        if (defined $nvme->{percentage_used} && $nvme->{percentage_used} =~ /^\d+$/) {
            my $left = 100 - $nvme->{percentage_used};
            $rec->{life_remaining} = $left < 0 ? 0 : $left;
        }
    }

    # SAS/SCSI solid state drives report endurance as a percentage used
    my $scsi_used = $j->{scsi_percentage_used_endurance_indicator};
    $scsi_used = $j->{endurance_used}{current_percent}
        if !defined $scsi_used && ref($j->{endurance_used}) eq 'HASH';
    if (defined $scsi_used && $scsi_used =~ /^\d+$/) {
        $seen_data = 1;
        my $left = 100 - $scsi_used;
        $rec->{life_remaining} = $left < 0 ? 0 : $left;
    }

    $rec->{state} = 'unreadable' unless $seen_data;
    return $rec;
}

# ============================================================================
# Evaluation
# ============================================================================

sub _short_device_name {
    my ($dev) = @_;
    my $name = $dev->{name};
    # A device that is gone is listed by GUID; the original path is in the message
    $name = $1 if $name =~ /^\d+$/ && $dev->{message} =~ /was (\S+)/;
    $name =~ s{^/dev/}{};
    return $name;
}

sub _format_eta {
    my ($seconds) = @_;
    return unless defined $seconds;
    return 'less than a minute' if $seconds < 60;
    return _plural(int(($seconds + 30) / 60), 'minute') if $seconds < 3600;
    return _plural(int(($seconds + 1800) / 3600), 'hour') if $seconds < 86400;
    return _plural(int(($seconds + 43200) / 86400), 'day');
}

sub _plural {
    my ($count, $unit) = @_;
    return "$count $unit" . ($count == 1 ? '' : 's');
}

sub _issue {
    my ($severity, $category, $text) = @_;
    return { severity => $severity, category => $category, text => $text };
}

my %MEMBER_STATE_TEXT = (
    REMOVED  => 'removed',
    UNAVAIL  => 'unavailable',
    FAULTED  => 'faulted',
    OFFLINE  => 'offline',
);

sub _zfs_issues {
    my ($pools) = @_;
    my @issues;

    foreach my $pool (@$pools) {
        my $name = $pool->{name};

        my %bad;
        my @counters;
        foreach my $dev (grep { $_->{leaf} } @{ $pool->{devices} }) {
            if ($MEMBER_STATE_TEXT{ $dev->{state} }) {
                $bad{ $dev->{state} }++;
            }
            elsif ($dev->{state} eq 'ONLINE'
                   && grep { $_ ne '0' } @{$dev}{qw(read write cksum)}) {
                push @counters, _short_device_name($dev);
            }
        }

        my @reasons = map { _plural($bad{$_}, 'drive') . " $MEMBER_STATE_TEXT{$_}" }
            grep { $bad{$_} } qw(REMOVED UNAVAIL FAULTED OFFLINE);
        # "1 drive removed" reads better as "drive removed"
        s/^1 drive/drive/ for @reasons;

        if ($pool->{state} ne 'ONLINE') {
            my $text = "$name $pool->{state}";
            $text .= ': ' . join(', ', @reasons) if @reasons;
            push @issues, _issue(SEV_CRITICAL, 'zfs_state', $text);
        }
        elsif (@reasons) {
            # e.g. a removed cache or log device does not degrade the pool
            push @issues, _issue(SEV_WARNING, 'zfs_member', "$name: " . join(', ', @reasons));
        }

        if ($pool->{data_errors}) {
            push @issues, _issue(SEV_CRITICAL, 'zfs_errors', "$name: data errors");
        }

        if (@counters) {
            my @shown = @counters > 2 ? (@counters[0, 1], '+' . (@counters - 2) . ' more') : @counters;
            push @issues, _issue(SEV_WARNING, 'zfs_counters',
                "$name: read/write/checksum errors on " . join(', ', @shown));
        }

        my $scan = $pool->{scan};
        if ($scan->{state} eq 'running') {
            my $text = $scan->{kind} eq 'resilver' ? "$name resilvering" : "$name scrubbing";
            my @progress;
            push @progress, sprintf('%d%%', $scan->{percent}) if defined $scan->{percent};
            my $eta = _format_eta($scan->{eta});
            push @progress, "$eta remaining" if defined $eta;
            $text .= ': ' . join(', ', @progress) if @progress;
            push @issues, $scan->{kind} eq 'resilver'
                ? _issue(SEV_WARNING, 'zfs_resilver', $text)
                : _issue(SEV_INFO, 'zfs_scrub', $text);
        }
    }

    return @issues;
}

sub _smart_issues {
    my ($devices, $life_warning, $life_critical) = @_;
    my @issues;

    foreach my $dev (@$devices) {
        next if $dev->{state} && $dev->{state} ne 'ok';
        my $name = $dev->{name};

        if (defined $dev->{passed} && !$dev->{passed}) {
            push @issues, _issue(SEV_CRITICAL, 'smart_fail', "$name SMART failure");
        }

        my @failing = @{ $dev->{failing_attrs} // [] };
        if (@failing) {
            my $text = "$name SMART attribute failing: $failing[0]";
            $text .= ' (+' . (@failing - 1) . ' more)' if @failing > 1;
            push @issues, _issue(SEV_CRITICAL, 'smart_attr', $text);
        }

        if (defined $dev->{critical_warning} && $dev->{critical_warning}) {
            my (@reasons, $severity);
            foreach my $bit (@NVME_WARNING_BITS) {
                next unless $dev->{critical_warning} & $bit->[0];
                push @reasons, $bit->[1];
                $severity = $bit->[2] if !$severity || $bit->[2] > $severity;
            }
            push @issues, _issue($severity // SEV_CRITICAL, 'nvme_warning',
                "$name critical warning: " . (join(', ', @reasons) || 'unknown'));
        }

        if (defined $dev->{life_remaining}) {
            my $severity = $dev->{life_remaining} <= $life_critical ? SEV_CRITICAL
                         : $dev->{life_remaining} <= $life_warning  ? SEV_WARNING
                         : 0;
            push @issues, _issue($severity, 'life', "$name life remaining: $dev->{life_remaining}%")
                if $severity;
        }
    }

    return @issues;
}

# Combines ZFS and SMART findings into the summary served to the UI.
# Arguments (hashref):
#   pools          arrayref from parse_zpool_status, undef if ZFS is unavailable
#   devices        arrayref of parse_smartctl_json records, undef if unavailable
#   smart_enabled  0 when SMART checks are switched off
#   smart_updated  epoch seconds the SMART results were last refreshed
#   smart_interval seconds between SMART queries (to tell stale results)
#   life_warning, life_critical, now
sub evaluate_storage_health {
    my ($args) = @_;

    my $now           = $args->{now} // time();
    my $life_warning  = $args->{life_warning}  // 20;
    my $life_critical = $args->{life_critical} // 10;
    my $pools         = $args->{pools};
    my $devices       = $args->{devices};
    my $smart_enabled = $args->{smart_enabled} // 1;

    my @issues;
    push @issues, _zfs_issues($pools) if $pools;
    push @issues, _smart_issues($devices, $life_warning, $life_critical) if $devices;

    my %smart = (enabled => $smart_enabled ? \1 : \0, available => $devices ? \1 : \0);
    if ($devices) {
        my @readable = grep { ($_->{state} // 'ok') ne 'unreadable' } @$devices;
        $smart{devices}   = 0 + @readable;
        $smart{sleeping}  = 0 + grep { $_->{sleeping} } @readable;
        $smart{unchecked} = 0 + grep { !$_->{checked} && ($_->{state} // '') eq 'pending' } @readable;
        $smart{updated}   = $args->{smart_updated} if defined $args->{smart_updated};

        my $max_age = ($args->{smart_interval} // 1800) * 3;
        $max_age = 900 if $max_age < 900;
        my @stale = grep { !$_->{sleeping} && $_->{checked} && $now - $_->{checked} > $max_age } @readable;
        push @issues, _issue(SEV_INFO, 'smart_info', 'SMART data is out of date') if @stale;
    }
    elsif ($smart_enabled) {
        push @issues, _issue(SEV_INFO, 'smart_info', 'SMART data unavailable');
    }

    @issues = sort {
        $b->{severity} <=> $a->{severity}
            || ($RANK{ $a->{category} } // 99) <=> ($RANK{ $b->{category} } // 99)
            || $a->{text} cmp $b->{text}
    } @issues;

    my $status = 'ok';
    $status = $SEVERITY_NAME{ $issues[0]{severity} } if @issues;

    my $summary = @issues ? $issues[0]{text} : 'OK';
    if (!@issues && !$pools && !$devices) {
        $status  = 'unknown';
        $summary = 'No storage health data available';
    }

    return {
        status  => $status,
        summary => $summary,
        issues  => [ map { { severity => $SEVERITY_NAME{ $_->{severity} }, text => $_->{text} } }
                         @issues[0 .. ($#issues > 19 ? 19 : $#issues)] ],
        zfs     => { available => $pools ? \1 : \0, pools => $pools ? 0 + @$pools : 0 },
        smart   => \%smart,
        updated => $now,
    };
}

# ============================================================================
# Collector — runs inside the node_info worker (as www-data)
# ============================================================================

sub collector_for_storage_health {
    $process_type = 'collector';
    $0 = 'collector-storage-health';
    debug(__LINE__, "Storage health collector started");

    # Inherited from the worker, whose handler would steal our children's exit status
    $SIG{CHLD} = 'DEFAULT';

    my $shutdown = 0;
    setup_collector_signals('storage-health', \$shutdown);

    my $interval = _clamp_int($config{storage_health}{zfs_interval}, 5, 3600, 15);
    my $last_run = 0;

    while (!$shutdown) {
        if (time() - $last_run >= $interval) {
            $last_run = time();
            my $summary = eval { _collect_storage_health() };
            if ($@ || !$summary) {
                debug(__LINE__, "Storage health collection failed: " . ($@ || 'no result'));
            } else {
                _write_json_atomic($storage_health_state_file, $summary);
            }
        }
        sleep 1 unless $shutdown;
    }

    debug(__LINE__, "Storage health collector shutting down");
    exit 0;
}

sub _collect_storage_health {
    my $cfg = $config{storage_health};

    my $pools;
    my $zpool_text = _read_zpool_status();
    $pools = parse_zpool_status($zpool_text) if defined $zpool_text;

    my ($devices, $smart_updated);
    my $smart_enabled = $cfg->{smart_enabled} ? 1 : 0;
    if ($smart_enabled) {
        my $smart = _read_smart_results();
        ($devices, $smart_updated) = @$smart{qw(devices updated)} if $smart;
    }

    my $life_warning  = _clamp_int($cfg->{life_warning_percent},  0, 100, 20);
    my $life_critical = _clamp_int($cfg->{life_critical_percent}, 0, 100, 10);
    $life_warning = $life_critical if $life_warning < $life_critical;

    return evaluate_storage_health({
        pools          => $pools,
        devices        => $devices,
        smart_enabled  => $smart_enabled,
        smart_updated  => $smart_updated,
        smart_interval => _clamp_int($cfg->{smart_interval}, 60, 86400, 1800),
        life_warning   => $life_warning,
        life_critical  => $life_critical,
    });
}

sub _read_zpool_status {
    if ($config{debug}{storage_health_mode}) {
        debug(__LINE__, "Debug mode: reading zpool status from $config{debug}{zpool_output_file}");
        return _slurp($config{debug}{zpool_output_file});
    }

    my $zpool = _find_binary('zpool') or return;
    my ($out, $rc) = _run_command(15, $zpool, 'status', '-LP');
    return unless defined $out && defined $rc && $rc == 0;
    return $out;
}

# Returns { devices => [...], updated => epoch }, or undef if there are none.
sub _read_smart_results {
    if ($config{debug}{storage_health_mode}) {
        debug(__LINE__, "Debug mode: reading smartctl output from $config{debug}{smartctl_output_file}");
        my $text = _slurp($config{debug}{smartctl_output_file});
        return unless defined $text;
        my $decoded = eval { decode_json($text) };
        return unless defined $decoded;

        my @records = grep { $_ } map { parse_smartctl_json($_) }
            (ref($decoded) eq 'ARRAY' ? @$decoded : ($decoded));
        my $now = time();
        $_->{checked} = $now for @records;
        return { devices => \@records, updated => $now };
    }

    my $text = _slurp($smart_snapshot_file);
    return unless defined $text;
    my $snapshot = eval { decode_json($text) };
    return unless ref($snapshot) eq 'HASH' && ref($snapshot->{devices}) eq 'ARRAY';
    return { devices => $snapshot->{devices}, updated => $snapshot->{updated} };
}

# ============================================================================
# SMART service — runs as root from systemd
# ============================================================================

sub smart_service_main {
    $0 = 'pve-mods-storage-smart';
    debug(__LINE__, "SMART service started");

    my $smartctl = _find_binary('smartctl');
    die "smartctl not found; install smartmontools\n" unless $smartctl;

    my $shutdown = 0;
    setup_collector_signals('storage-smart', \$shutdown);

    my $cfg      = $config{storage_health};
    my $interval = _clamp_int($cfg->{smart_interval}, 60, 86400, 1800);
    my $wake     = $cfg->{smart_wake_disks} ? 1 : 0;

    # Resume from the previous run so a service restart does not query every
    # drive (and wake sleeping ones) again.
    my $previous  = eval { decode_json(_slurp($smart_snapshot_file) // '{}') };
    $previous = {} unless ref($previous) eq 'HASH';
    my $inventory = $previous->{inventory} // '';
    my @scan      = ref($previous->{scan}) eq 'ARRAY' ? @{ $previous->{scan} } : ();
    my %results   = map { $_->{dev} => $_ }
        grep { ref($_) eq 'HASH' && defined $_->{dev} }
        (ref($previous->{devices}) eq 'ARRAY' ? @{ $previous->{devices} } : ());

    my (%next_attempt, $last_write);
    $last_write = 0;

    while (!$shutdown) {
        my $now = time();
        my $changed = 0;

        # Device discovery opens every drive, so it only runs when the set of
        # block devices changed.
        my $current_inventory = _block_inventory();
        if ($current_inventory ne $inventory) {
            debug(__LINE__, "Block device inventory changed, scanning for SMART devices");
            @scan      = _scan_devices($smartctl);
            %results   = ();
            %next_attempt = ();
            $inventory = $current_inventory;
            $changed   = 1;
        }

        foreach my $target (@scan) {
            last if $shutdown;
            my $dev = $target->{dev};
            my $rec = $results{$dev};

            next if $rec && !$rec->{sleeping} && $now - ($rec->{checked} // 0) < $interval;
            next if ($next_attempt{$dev} // 0) > $now;

            my $result = _query_device($smartctl, $target, $wake);
            if (!$result) {
                $next_attempt{$dev} = $now + 300;
                next;
            }
            $changed = 1;

            if ($result->{state} eq 'sleeping') {
                # Keep the last real result; it is flagged as cached
                $rec //= { name => $result->{name}, dev => $dev, state => 'pending', checked => 0 };
                $rec->{sleeping} = 1;
                $results{$dev} = $rec;
                $next_attempt{$dev} = $now + 300;
            } else {
                $result->{checked}  = $now;
                $result->{sleeping} = 0;
                $results{$dev} = $result;
            }
        }

        if ($changed || $now - $last_write >= 60) {
            my @records = map { $results{$_->{dev}} } grep { $results{$_->{dev}} } @scan;
            _write_json_atomic($smart_snapshot_file, {
                updated   => $now,
                inventory => $inventory,
                scan      => \@scan,
                devices   => \@records,
            });
            $last_write = $now;
        }

        for (1 .. 5) {
            last if $shutdown;
            sleep 1;
        }
    }

    debug(__LINE__, "SMART service shutting down");
    return 1;
}

sub _block_inventory {
    opendir(my $dh, '/sys/block') or return '';
    my @names = sort grep { !/^(?:\.|loop|ram|zd|dm-|sr|md|nbd|zram|fd)/ } readdir($dh);
    closedir($dh);
    return join(',', @names);
}

sub _scan_devices {
    my ($smartctl) = @_;

    my ($out) = _run_command(120, $smartctl, '--scan-open', '-j');
    return () unless defined $out;
    my $json = eval { decode_json($out) };
    return () unless ref($json) eq 'HASH' && ref($json->{devices}) eq 'ARRAY';

    my (@targets, %seen);
    foreach my $d (@{ $json->{devices} }) {
        next unless ref($d) eq 'HASH';
        my $dev  = $d->{name} // '';
        my $type = $d->{type} // '';
        next unless $dev =~ m{^/dev/[A-Za-z0-9_/.\-]+$};
        next if $seen{$dev}++;
        $type = '' unless $type =~ /^[A-Za-z0-9,+\-]+$/;
        push @targets, { dev => $dev, type => $type, protocol => lc($d->{protocol} // '') };
    }
    return @targets;
}

sub _query_device {
    my ($smartctl, $target, $wake) = @_;

    my @cmd = ($smartctl, '-a', '-j');
    # NVMe drives have no rotating media, so there is nothing to skip for them
    push @cmd, '-n', 'standby' unless $wake || $target->{protocol} eq 'nvme';
    push @cmd, '-d', $target->{type} if $target->{type} && $target->{type} ne 'auto';
    push @cmd, $target->{dev};

    my ($out) = _run_command(60, @cmd);
    return unless defined $out;

    my $rec = parse_smartctl_json($out);
    return unless $rec;

    $rec->{dev}  = $target->{dev};
    ($rec->{name}) = $target->{dev} =~ m{([^/]+)$};
    return $rec;
}

1;
