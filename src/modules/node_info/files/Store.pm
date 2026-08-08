package PVE::PVEMod::Store;

use strict;
use warnings;
use Exporter 'import';

use File::Path qw(make_path);
use PVE::INotify;
use RRDs;

use PVE::PVEMod::Config qw(%config $RRD_SOCKET $RRD_BASE);
use PVE::PVEMod::Utils  qw(debug);

our @EXPORT_OK = qw(
    get_nodename
    gpu_rrd_path
    update_intel_gpu_rrd
    update_nvidia_gpu_rrd
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

sub gpu_rrd_path {
    my ($card) = @_;
    return "$RRD_BASE/" . get_nodename() . "/$card";
}

# ============================================================================
# Intel GPU RRD
# ============================================================================

sub _ensure_intel_gpu_rrd {
    return unless $config{gpu}{gpu_history};

    my ($card) = @_;
    my $path = gpu_rrd_path($card);
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
        'RRA:AVERAGE:0.5:1800:1344',
        'RRA:AVERAGE:0.5:21600:1464',
        'RRA:AVERAGE:0.5:604800:520',
        'RRA:MAX:0.5:1:1440',
        'RRA:MAX:0.5:60:1440',
        'RRA:MAX:0.5:1800:1344',
        'RRA:MAX:0.5:21600:1464',
        'RRA:MAX:0.5:604800:520',
    );
    my $err = RRDs::error();
    debug(__LINE__, "Created Intel GPU RRD $path: " . ($err // 'OK'));
}

sub update_intel_gpu_rrd {
    my ($card, $stats) = @_;
    _ensure_intel_gpu_rrd($card);
    my $path = gpu_rrd_path($card);

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
    debug(__LINE__, "RRD update intel $card: $err") if $err;
}

# ============================================================================
# NVIDIA GPU RRD
# ============================================================================

sub _ensure_nvidia_gpu_rrd {
    return unless $config{gpu}{gpu_history};

    my ($index) = @_;
    my $card = "nvidia$index";
    my $path = gpu_rrd_path($card);
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
        'RRA:AVERAGE:0.5:1800:1344',
        'RRA:AVERAGE:0.5:21600:1464',
        'RRA:AVERAGE:0.5:604800:520',
        'RRA:MAX:0.5:1:1440',
        'RRA:MAX:0.5:60:1440',
        'RRA:MAX:0.5:1800:1344',
        'RRA:MAX:0.5:21600:1464',
        'RRA:MAX:0.5:604800:520',
    );
    my $err = RRDs::error();
    debug(__LINE__, "Created NVIDIA GPU RRD $path: " . ($err // 'OK'));
}

sub update_nvidia_gpu_rrd {
    my ($index, $stats) = @_;
    _ensure_nvidia_gpu_rrd($index);
    my $card = "nvidia$index";
    my $path = gpu_rrd_path($card);

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
    debug(__LINE__, "RRD update nvidia$index: $err") if $err;
}

1;
