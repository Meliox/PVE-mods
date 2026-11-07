package PVE::PVEMods::Store;

use strict;
use warnings;
use Exporter 'import';

use File::Path qw(make_path);
use PVE::INotify;
use RRDs;

use PVE::PVEMods::Config qw(%config $RRD_SOCKET $RRD_BASE);
use PVE::PVEMods::Utils  qw(debug);

our @EXPORT_OK = qw(
    get_nodename
    gpu_history_id
    gpu_rrd_path
    update_intel_gpu_rrd
    update_nvidia_gpu_rrd
    update_amd_gpu_rrd
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
# Intel GPU RRD
# ============================================================================

sub _ensure_intel_gpu_rrd {
    return unless $config{gpu}{gpu_history};

    my ($id) = @_;
    my $path = gpu_rrd_path($id);
    return if -f $path;

    my $dir = "$RRD_BASE/" . get_nodename();
    make_path($dir, { mode => 0755 }) unless -d $dir;

    RRDs::create(
        $path,
        '--step', '1',
        'DS:freq_req:GAUGE:120:0:U',
        'DS:freq_act:GAUGE:120:0:U',
        'DS:rc6:GAUGE:120:0:100',
        'DS:power_gpu:GAUGE:120:0:U',
        'DS:power_pkg:GAUGE:120:0:U',
        'DS:render_busy:GAUGE:120:0:100',
        'DS:blitter_busy:GAUGE:120:0:100',
        'DS:video_busy:GAUGE:120:0:100',
        'DS:videnh_busy:GAUGE:120:0:100',
        'RRA:AVERAGE:0.5:1:1440',
        'RRA:AVERAGE:0.5:60:1440',
        'RRA:AVERAGE:0.5:1800:1440',
        'RRA:AVERAGE:0.5:21600:1464',
        'RRA:AVERAGE:0.5:604800:520',
        'RRA:MAX:0.5:1:1440',
        'RRA:MAX:0.5:60:1440',
        'RRA:MAX:0.5:1800:1440',
        'RRA:MAX:0.5:21600:1464',
        'RRA:MAX:0.5:604800:520',
    );
    my $err = RRDs::error();
    debug(__LINE__, "Created Intel GPU RRD $path: " . ($err // 'OK'));
}

sub update_intel_gpu_rrd {
    my ($id, $stats) = @_;
    return unless $config{gpu}{gpu_history};

    _ensure_intel_gpu_rrd($id);
    my $path = gpu_rrd_path($id);

    my $freq_req    = $stats->{frequency}{requested}        // 'U';
    my $freq_act    = $stats->{frequency}{actual}           // 'U';
    my $rc6         = $stats->{rc6}{value}                  // 'U';
    my $power_gpu   = $stats->{power}{GPU}                  // 'U';
    my $power_pkg   = $stats->{power}{Package}              // 'U';
    my $render_busy = $stats->{engines}{'Render/3D'}{busy}  // 'U';
    my $blitter     = $stats->{engines}{Blitter}{busy}      // 'U';
    my $video       = $stats->{engines}{Video}{busy}        // 'U';
    my $videnh      = $stats->{engines}{VideoEnhance}{busy} // 'U';

    my @daemon_args = (-S $RRD_SOCKET) ? ('--daemon', "unix:$RRD_SOCKET") : ();
    RRDs::update(
        $path,
        @daemon_args,
        "N:$freq_req:$freq_act:$rc6:$power_gpu:$power_pkg:$render_busy:$blitter:$video:$videnh",
    );
    my $err = RRDs::error();
    debug(__LINE__, "RRD update intel $id: $err") if $err;
}

# ============================================================================
# NVIDIA GPU RRD
# ============================================================================

sub _ensure_nvidia_gpu_rrd {
    return unless $config{gpu}{gpu_history};

    my ($id) = @_;
    my $path = gpu_rrd_path($id);
    return if -f $path;

    my $dir = "$RRD_BASE/" . get_nodename();
    make_path($dir, { mode => 0755 }) unless -d $dir;

    RRDs::create(
        $path,
        '--step', '1',
        'DS:gpu_util:GAUGE:120:0:100',
        'DS:mem_util:GAUGE:120:0:100',
        'DS:mem_used:GAUGE:120:0:U',
        'DS:mem_total:GAUGE:120:0:U',
        'DS:power_draw:GAUGE:120:0:U',
        'DS:power_limit:GAUGE:120:0:U',
        'DS:temp_gpu:GAUGE:120:0:U',
        'DS:fan_speed:GAUGE:120:0:100',
        'RRA:AVERAGE:0.5:1:1440',
        'RRA:AVERAGE:0.5:60:1440',
        'RRA:AVERAGE:0.5:1800:1440',
        'RRA:AVERAGE:0.5:21600:1464',
        'RRA:AVERAGE:0.5:604800:520',
        'RRA:MAX:0.5:1:1440',
        'RRA:MAX:0.5:60:1440',
        'RRA:MAX:0.5:1800:1440',
        'RRA:MAX:0.5:21600:1464',
        'RRA:MAX:0.5:604800:520',
    );
    my $err = RRDs::error();
    debug(__LINE__, "Created NVIDIA GPU RRD $path: " . ($err // 'OK'));
}

sub update_nvidia_gpu_rrd {
    my ($id, $stats) = @_;
    return unless $config{gpu}{gpu_history};

    _ensure_nvidia_gpu_rrd($id);
    my $path = gpu_rrd_path($id);

    my $gpu_util    = $stats->{utilization}{gpu}    // 'U';
    my $mem_util    = $stats->{utilization}{memory} // 'U';
    my $mem_used    = $stats->{memory}{used}        // 'U';
    my $mem_total   = $stats->{memory}{total}       // 'U';
    my $power_draw  = $stats->{power}{draw}         // 'U';
    my $power_limit = $stats->{power}{limit}        // 'U';
    my $temp_gpu    = $stats->{temperature}{gpu}    // 'U';
    my $fan_speed   = $stats->{fan}{speed}          // 'U';

    my @daemon_args = (-S $RRD_SOCKET) ? ('--daemon', "unix:$RRD_SOCKET") : ();
    RRDs::update(
        $path,
        @daemon_args,
        "N:$gpu_util:$mem_util:$mem_used:$mem_total:$power_draw:$power_limit:$temp_gpu:$fan_speed",
    );
    my $err = RRDs::error();
    debug(__LINE__, "RRD update nvidia $id: $err") if $err;
}

sub update_amd_gpu_rrd {
    my ($id, $stats) = @_;
    return unless $config{gpu}{gpu_history};
    my @fields = qw(gpu_util mem_util mem_used mem_total gtt_used gtt_total freq_act power_draw temp_gpu fan_rpm);
    my @values = map {
        my ($group, $key) = @$_;
        ref($stats->{$group}) eq 'HASH' ? $stats->{$group}{$key} : undef;
    } (
        ['utilization', 'gpu'], ['utilization', 'memory'],
        ['memory', 'used'], ['memory', 'total'],
        ['gtt', 'used'], ['gtt', 'total'],
        ['frequency', 'actual'], ['power', 'draw'],
        ['temperature', 'gpu'], ['fan', 'speed'],
    );
    my $path = gpu_rrd_path($id);
    unless (-f $path) {
        my $dir = "$RRD_BASE/" . get_nodename();
        make_path($dir, { mode => 0755 }) unless -d $dir;
        RRDs::create($path, '--step', '1',
            (map { "DS:$_:GAUGE:120:" . ($_ eq 'temp_gpu' ? 'U' : 0) . ':'
                . (/^(gpu_util|mem_util)$/ ? 100 : 'U') } @fields),
            (map { my $cf = $_; map { "RRA:$cf:0.5:$_" }
                qw(1:1440 60:1440 1800:1440 21600:1464 604800:520) } qw(AVERAGE MAX)));
        if (my $err = RRDs::error()) {
            warn "AMD GPU: cannot create RRD $path: $err\n";
            return;
        }
    }
    my @daemon_args = (-S $RRD_SOCKET) ? ('--daemon', "unix:$RRD_SOCKET") : ();
    RRDs::update($path, @daemon_args, 'N:' . join(':', map { defined $_ ? $_ : 'U' } @values));
    my $err = RRDs::error();
    warn "AMD GPU: cannot update RRD $path: $err\n" if $err;
}

1;
