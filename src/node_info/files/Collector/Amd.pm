package PVE::PVEMod::Collector::Amd;

use strict;
use warnings;
use Exporter 'import';

use PVE::PVEMod::Config qw($process_type);
use PVE::PVEMod::Utils  qw(debug);

our @EXPORT_OK = qw(
    get_amd_gpu_devices
    collector_for_amd_device
);

# ============================================================================
# AMD GPU — placeholders (not yet implemented)
# ============================================================================

sub get_amd_gpu_devices {
    # TODO: Implement AMD GPU detection using rocminfo or rocm-smi
    debug(__LINE__, "AMD GPU support not yet implemented");
    return ();
}

sub collector_for_amd_device {
    my ($device) = @_;
    $process_type = 'collector';
    # TODO: Implement AMD GPU collector
    debug(__LINE__, "AMD GPU collector not yet implemented");
    exit 0;
}

1;
