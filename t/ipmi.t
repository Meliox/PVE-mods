use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use FindBin;

require "$FindBin::Bin/../src/modules/node_info/files/Collector/Ipmi.pm";

sub fixture {
    my ($name) = @_;
    open my $fh, '<', "$FindBin::Bin/../build/test/fixtures/ipmi/$name" or die $!;
    local $/;
    return <$fh>;
}

my $sensors = PVE::PVEMod::Collector::Ipmi::parse_sensor_output(
    fixture('tyan-s8026-sensor.txt'));
is(scalar @$sensors, 10, 'all rows kept, including unavailable and discrete sensors');

my %by_name = map { $_->{name} => $_ } @$sensors;
is($by_name{CPU_Tctl_Value}{value}, 71, 'CPU reading parsed');
is($by_name{CPU_Tctl_Value}{category}, 'temperature', 'temperature classified');
is($by_name{CPU_Tctl_Value}{unit}, "\x{b0}C", 'temperature unit is valid Unicode');
is($by_name{CPU_Tctl_Value}{thresholds}{upper_critical}, 95, 'critical threshold parsed');
is($by_name{SYS_Air_Inlet}{value}, 0, 'zero is preserved as a real reported reading');
ok($by_name{SYS_Air_Inlet}{available}, 'zero reading remains available');
ok(!defined $by_name{P0_D1_UMC0_CH_A}{value}, 'No Reading is null');
ok(!$by_name{P0_D1_UMC0_CH_A}{available}, 'No Reading is unavailable');
is($by_name{SYS_FAN_1}{thresholds}{lower_critical}, 800, 'fan threshold parsed');
is($by_name{PSU0_PIN}{unit}, 'W', 'power unit normalized');
is($by_name{VCC12}{unit}, 'V', 'voltage unit normalized');
is($by_name{PSU1_Status}{category}, 'other', 'discrete sensor retained without false health alarm');

my $dcmi = PVE::PVEMod::Collector::Ipmi::parse_dcmi_output(
    fixture('tyan-s8026-dcmi.txt'));
is($dcmi->{instantaneous_watts}, 104, 'DCMI instantaneous power parsed');
is($dcmi->{average_watts}, 80, 'DCMI average power parsed');
is($dcmi->{sampling_seconds}, 5, 'DCMI sample period parsed');
ok($dcmi->{available}, 'activated DCMI reading is available');

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/snapshot.json";
PVE::PVEMod::Collector::Ipmi::write_snapshot($path, {
    schema_version => 1, sensors => $sensors, dcmi => $dcmi,
});
open my $fh, '<', $path or die $!;
local $/;
my $saved = JSON::PP->new->utf8->decode(<$fh>);
close $fh;
is($saved->{schema_version}, 1, 'snapshot written as JSON');
is((stat $path)[2] & 0777, 0644, 'snapshot readable by API process');

PVE::PVEMod::Collector::Ipmi::write_snapshot($path, { schema_version => 2 });
open $fh, '<', $path or die $!;
my $replaced = JSON::PP->new->utf8->decode(<$fh>);
close $fh;
is($replaced->{schema_version}, 2, 'snapshot replaced atomically');

done_testing();
