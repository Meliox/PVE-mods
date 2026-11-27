package PVE::PVEMods::Store;

use strict;
use warnings;
use Exporter 'import';

use File::Path qw(make_path);
use PVE::INotify;
use RRDs;

use PVE::PVEMods::Config qw(%config $RRD_BASE);
use PVE::PVEMods::Utils  qw(debug);

our @EXPORT_OK = qw(
    get_nodename
    gpu_history_id
    gpu_rrd_path
    update_gpu_rrd
    flush_gpu_rrds
    read_gpu_rrd_data
);

# ============================================================================
# Node name
# ============================================================================

sub get_nodename {
    return PVE::INotify::nodename();
}

# ============================================================================
# RRD path helper
# ============================================================================

# Stable identifier of a GPU's RRD file, derived from its PCI address
# ("0000:00:02.0" or "00000000:01:00.0" -> "pci000000020"). Unlike cardN or the
# NVIDIA index it does not change when the enumeration order does. Falls back
# to $fallback when the address is unknown. Matches [a-zA-Z0-9]+ as required by
# the gpurrddata API.
sub gpu_history_id {
    my ($pci_addr, $fallback) = @_;
    if (defined $pci_addr
        && $pci_addr =~ /^(?:[0-9a-f]{4})?([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$/i) {
        return lc("pci$1$2$3$4");
    }
    return $fallback;
}

sub gpu_rrd_path {
    my ($id) = @_;
    return "$RRD_BASE/" . get_nodename() . "/$id";
}

# ============================================================================
# GPU RRD schemas
# ============================================================================

# One schema per vendor: RRD data source name, minimum, maximum, and where the
# collector publishes the value in its stats hash. All vendors share the same
# step and archives, so a single code path creates, updates and reads every
# GPU history file.
my %gpu_rrd_schemas = (
    intel => {
        label  => 'Intel GPU',
        fields => [
            # name             min  max   location in $stats
            ['freq_req',       0,   'U',  'frequency', 'requested'],
            ['freq_act',       0,   'U',  'frequency', 'actual'],
            ['rc6',            0,   100,  'rc6', 'value'],
            ['power_gpu',      0,   'U',  'power', 'GPU'],
            ['power_pkg',      0,   'U',  'power', 'Package'],
            ['render_busy',    0,   100,  'engines', 'Render/3D', 'busy'],
            ['blitter_busy',   0,   100,  'engines', 'Blitter', 'busy'],
            ['video_busy',     0,   100,  'engines', 'Video', 'busy'],
            ['videnh_busy',    0,   100,  'engines', 'VideoEnhance', 'busy'],
        ],
    },
    nvidia => {
        label  => 'NVIDIA GPU',
        fields => [
            ['gpu_util',       0,   100,  'utilization', 'gpu'],
            ['mem_util',       0,   100,  'utilization', 'memory'],
            ['mem_used',       0,   'U',  'memory', 'used'],
            ['mem_total',      0,   'U',  'memory', 'total'],
            ['power_draw',     0,   'U',  'power', 'draw'],
            ['power_limit',    0,   'U',  'power', 'limit'],
            ['temp_gpu',       0,   'U',  'temperature', 'gpu'],
            ['fan_speed',      0,   100,  'fan', 'speed'],
        ],
    },
    amd => {
        label  => 'AMD GPU',
        fields => [
            ['gpu_util',       0,   100,  'utilization', 'gpu'],
            ['mem_util',       0,   100,  'utilization', 'memory'],
            ['mem_used',       0,   'U',  'memory', 'used'],
            ['mem_total',      0,   'U',  'memory', 'total'],
            ['gtt_used',       0,   'U',  'gtt', 'used'],
            ['gtt_total',      0,   'U',  'gtt', 'total'],
            ['freq_act',       0,   'U',  'frequency', 'actual'],
            ['power_draw',     0,   'U',  'power', 'draw'],
            ['temp_gpu',       'U', 'U',  'temperature', 'gpu'],
            ['fan_rpm',        0,   'U',  'fan', 'speed'],
        ],
    },
);

# Keep the existing archive layout for both new and existing files. The graph
# API uses minute-or-coarser data, but removing the per-second archives would
# change the schema and requires a separate decision about existing files.
my @gpu_rrd_archives = map {
    my $cf = $_;
    map { "RRA:$cf:0.5:$_" } qw(1:1440 60:1440 1800:1440 21600:1464 604800:520)
} qw(AVERAGE MAX);

# ============================================================================
# GPU RRD writer
# ============================================================================

# The history files are owned by www-data and accessed directly. rrdcached's
# socket is root-only on Proxmox, so it cannot be used from here, and mixing
# cached and direct access to the same file could lose pending updates.
# Running the existing worker as root would prevent pveproxy from signalling
# it; a separate root recorder and protected reader would require another
# service, validation across a privilege boundary, and pvedaemon reloads.
#
# Each direct update has a substantial fixed disk-write cost. In a short ext4
# test, buffering 60s rather than 1s reduced writes from about 275 to 75 MiB/day
# per GPU; 300s reduced them further to about 31 MiB/day but adds graph delay.
# These are comparative measurements, not production guarantees. We keep each
# sample's timestamp, flush on collector exit, and accept that a crash or forced
# stop can lose the buffer. Unlike rrdcached, a direct reader cannot flush it.
# Host-wide kernel writeback changes would affect unrelated data and crash safety.
my %rrd_buffer;   # path => { label => ..., samples => [...], first => ts }
my %rrd_last_ts;  # path => newest queued timestamp, survives flushes
my %rrd_failed;   # path => 1 after a warned-about failure, to log only once
my %rrd_clock_warning;

sub _now { return time(); }

sub _ensure_gpu_rrd {
    my ($schema, $path, $now) = @_;
    return 1 if -f $path;

    my $dir = "$RRD_BASE/" . get_nodename();
    make_path($dir, { mode => 0755 }) unless -d $dir;

    RRDs::create(
        $path,
        '--start', $now - 1,
        '--step', '1',
        (map { "DS:$_->[0]:GAUGE:120:$_->[1]:$_->[2]" } @{ $schema->{fields} }),
        @gpu_rrd_archives,
    );
    if (my $err = RRDs::error()) {
        warn "$schema->{label}: cannot create RRD $path: $err\n" unless $rrd_failed{$path}++;
        return 0;
    }
    debug(__LINE__, "Created $schema->{label} RRD $path");
    return 1;
}

# Walks the stats hash without autovivifying missing branches.
sub _stats_value {
    my ($stats, @keys) = @_;
    my $node = $stats;
    for my $key (@keys) {
        return undef unless ref($node) eq 'HASH';
        $node = $node->{$key};
    }
    return $node;
}

sub _flush_rrd {
    my ($path) = @_;
    my $buf = delete $rrd_buffer{$path} or return;

    RRDs::update($path, @{ $buf->{samples} });
    if (my $err = RRDs::error()) {
        warn "$buf->{label}: cannot update RRD $path; buffered samples may be lost: $err\n"
            unless $rrd_failed{$path}++;
        return;
    }
    warn "$buf->{label}: RRD $path recovered, history recording resumed\n"
        if delete $rrd_failed{$path};
}

sub update_gpu_rrd {
    my ($vendor, $id, $stats) = @_;
    return unless $config{gpu}{gpu_history};

    # RRDs also uses rrdcached implicitly when this environment variable is set.
    local $ENV{RRDCACHED_ADDRESS};
    delete $ENV{RRDCACHED_ADDRESS};
    my $schema = $gpu_rrd_schemas{$vendor} or die "unknown GPU vendor '$vendor'\n";
    my $path = gpu_rrd_path($id);
    my $now = _now();
    return unless _ensure_gpu_rrd($schema, $path, $now);

    if (!defined $rrd_last_ts{$path}) {
        my $last = RRDs::last($path);
        if (my $err = RRDs::error()) {
            warn "$schema->{label}: cannot read last RRD timestamp $path: $err\n"
                unless $rrd_failed{$path}++;
            return;
        }
        $rrd_last_ts{$path} = $last;
    }

    if ($now < $rrd_last_ts{$path}) {
        warn "$schema->{label}: clock is behind the last RRD sample for $path; skipping history until it catches up\n"
            unless $rrd_clock_warning{$path}++;
        return;
    }
    delete $rrd_clock_warning{$path};

    my $sample = join(':', $now,
        map { _stats_value($stats, @{$_}[3 .. $#$_]) // 'U' } @{ $schema->{fields} });
    if ($now == $rrd_last_ts{$path}) {
        $rrd_buffer{$path}{samples}[-1] = $sample if $rrd_buffer{$path};
        return;
    }
    $rrd_last_ts{$path} = $now;

    my $buf = $rrd_buffer{$path} //= { label => $schema->{label}, samples => [], first => $now };
    push @{ $buf->{samples} }, $sample;

    _flush_rrd($path)
        if $now - $buf->{first} + 1 >= ($config{intervals}{gpu_history_flush} || 1);
}

# Writes out all buffered samples; collectors call this before exiting.
sub flush_gpu_rrds {
    local $ENV{RRDCACHED_ADDRESS};
    delete $ENV{RRDCACHED_ADDRESS};
    _flush_rrd($_) for keys %rrd_buffer;
}

# ============================================================================
# GPU RRD reader (gpurrddata API)
# ============================================================================

# Same windows as PVE::RRD::create_rrd_data, which cannot be used here because
# it reads through the root-only rrdcached socket whenever that exists.
my %timeframes = (
    hour   => [60, 60],
    day    => [60, 1440],
    week   => [60 * 30, 336],
    month  => [60 * 30, 1440],
    year   => [3600 * 6, 1440],
    decade => [86400 * 7, 570],
);

sub read_gpu_rrd_data {
    my ($id, $timeframe, $cf) = @_;
    die "invalid card name\n" unless defined $id && $id =~ /^[a-zA-Z0-9]+$/;
    my $window = $timeframes{$timeframe // ''} or die "invalid timeframe\n";
    local $ENV{RRDCACHED_ADDRESS};
    delete $ENV{RRDCACHED_ADDRESS};
    my ($reso, $count) = @$window;
    my $ctime = $reso * int(time() / $reso);

    my ($start, $step, $names, $rows) = RRDs::fetch(
        gpu_rrd_path($id), $cf || 'AVERAGE',
        '-s' => $ctime - $reso * $count, '-e' => $ctime - 1, '-r' => $reso,
    );
    my $err = RRDs::error();
    die "RRD error: $err\n" if $err;

    my @res;
    for my $row (@$rows) {
        my %entry = (time => $start);
        $start += $step;
        for my $i (0 .. $#$names) {
            $entry{ $names->[$i] } = $row->[$i] if defined $row->[$i];
        }
        push @res, \%entry;
    }
    # The newest bucket can still be empty right after a boundary.
    pop @res if @res && keys %{ $res[-1] } == 1;
    return \@res;
}

1;
