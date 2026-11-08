use strict;
use warnings;
use JSON::PP;
use lib "$ENV{NODE_INFO_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Collector::LmSensors;
use PVE::PVEMods::Config qw(%config);

# Writes the payload the collector would publish for a fixture, so the GUI
# tests consume real collector output instead of hand-built data.
my ($fixture, $out) = @ARGV;
die "usage: lm-sensors-payload.pl <fixture name> <output file>\n" unless $fixture && $out;

$config{debug}{lm_sensors_mode} = 1;
$config{debug}{lm_sensors_output_file} = "$ENV{LM_SENSORS_FIXTURES}/$fixture";
$config{lm_sensors}{$_} = 1 for qw(enable_cpu enable_ram_temp enable_hdd_temp enable_nvme_temp
    enable_fan_speed display_zero_speed_fans enable_other_temp);
$config{system_info}{temp_unit} = 'C';

# Pre-filled so the enrichment does not depend on the host's /sys and /proc.
# Keep in sync with primed_cache() in lm-sensors.t.
open my $in, '<', "$ENV{LM_SENSORS_FIXTURES}/$fixture" or die "$fixture: $!";
my $raw = do { local $/; <$in> };
close $in;
my %cache;
for my $chip (keys %{ decode_json($raw) }) {
    if ($chip =~ /^(?:coretemp-isa-|k10temp-pci-|cpu_thermal-virtual-)/) {
        my ($package) = $chip =~ /^coretemp-isa-(\d+)$/;
        $cache{$chip} = { model => 'Intel(R) Core(TM) Test <CPU>', package => ($package // 0) + 0 };
    } elsif ($chip =~ /^drivetemp-/) {
        $cache{$chip} = { device_path => '/dev/sda', model => 'Test SSD', serial => 'SER123' };
    } elsif ($chip =~ /^nvme-pci-/) {
        $cache{$chip} = { device_path => '/dev/nvme0n1', model => 'Test NVMe', serial => 'NVME456' };
    }
}
my $payload = PVE::PVEMods::Collector::LmSensors::_get_temperature_sensors(\%cache);
open my $fh, '>', $out or die "$out: $!";
print {$fh} $payload;
close $fh or die "$out: $!";
