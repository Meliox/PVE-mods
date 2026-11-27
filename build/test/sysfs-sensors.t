use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use JSON::PP qw(decode_json encode_json);

use lib "$ENV{NODE_INFO_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Collector::SysfsSensors qw(merge_sysfs_temperatures);
use PVE::PVEMods::Collector::LmSensors;
use PVE::PVEMods::Config qw(%config);

my $dir = tempdir(CLEANUP => 1);
my $root = "$dir/sys";
make_path("$root/class/test");
local $PVE::PVEMods::Collector::SysfsSensors::SYSFS_ROOT = $root;
local $PVE::PVEMods::Collector::SysfsSensors::SOURCES_FILE = "$dir/sources.json";
local $PVE::PVEMods::Collector::SysfsSensors::OVERRIDES_FILE = "$dir/overrides.json";
my $now = 100;
no warnings 'redefine';
local *PVE::PVEMods::Collector::SysfsSensors::_now = sub { $now };
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub write_file {
    my ($path, $value) = @_;
    open my $fh, '>', "$path.new" or die "$path: $!";
    print {$fh} $value;
    close $fh or die "$path: $!";
    rename "$path.new", $path or die "$path: $!";
}
sub overrides {
    write_file("$dir/overrides.json", encode_json({ sources => [@_] }));
}
sub device {
    my ($index, $value) = @_;
    my $path = "$root/devices/test/device$index";
    make_path($path);
    write_file("$path/temp", $value);
    symlink $path, "$root/class/test/device$index" or die "symlink: $!";
    return "$path/temp";
}
sub poll { merge_sysfs_temperatures({}, $_[0]); }

write_file("$dir/sources.json", encode_json({ sources => [{
    id => 'fixture', label => 'Test <sensor>&', path => '/sys/class/test/device*/temp',
    temp_scale => 0.001, max => 45, crit => 60,
}] }));
my %cache;
is_deeply(poll(\%cache), {}, 'absent hardware yields no readings');
is(scalar @warnings, 0, 'absent hardware does not warn');
my $first = device(0, "38050\n");
is_deeply(poll(\%cache), {}, 'negative discovery is cached');
$now += 60;
my $sensors = poll(\%cache);
my ($first_key) = keys %$sensors;
is($sensors->{$first_key}{label}, 'Test <sensor>&', 'source label is shown without the encoded sysfs path');
is_deeply($sensors->{$first_key}{temp1}{input},
    { value => 38.05, quantity => 'temperature', unit => 'C' }, 'source scale produces the lm-sensors feature schema');

device(1, "50000\n");
write_file($first, "40125\n");
$sensors = poll(\%cache);
is(scalar keys %$sensors, 1, 'positive discovery is cached too');
is($sensors->{$first_key}{temp1}{input}{value}, 40.125, 'cached paths yield fresh temperatures');
$now += 60;
is(scalar keys %{poll(\%cache)}, 2, 'rediscovery adds another device without collisions');
write_file($first, "invalid\n");
@warnings = ();
ok(!exists poll(\%cache)->{$first_key}, 'invalid readings do not retain their previous value');
poll(\%cache);
is(scalar @warnings, 1, 'read errors are reported without flooding logs');
unlink $first or die $!;
ok(!exists poll(\%cache)->{$first_key}, 'removed devices disappear immediately');
write_file($first, "38050\n");
is(poll(\%cache)->{$first_key}{temp1}{input}{value}, 38.05, 'readings recover automatically');

overrides({ id => 'fixture', enabled => JSON::PP::false });
is_deeply(poll(\%cache), {}, 'an override disables a source without waiting for expiry');
make_path("$root/class/extra");
write_file("$root/class/extra/temp", "125\n");
my $extra = { id => 'extra', label => 'Extra', path => '/sys/class/extra/temp', temp_scale => 0.1 };
overrides($extra, { id => 'fixture', label => 'Renamed' });
$sensors = poll(\%cache);
is(scalar keys %$sensors, 3, 'overrides can add sources');
is($sensors->{$first_key}{label}, 'Renamed', 'partial overrides retain the source label');
is($sensors->{$first_key}{temp1}{input}{value}, 38.05, 'partial overrides retain the source scale');
unlink "$dir/overrides.json" or die $!;
is(scalar keys %{poll(\%cache)}, 2, 'removing overrides restores defaults');

for my $entry ({ %$extra, path => '/etc/passwd' }, { %$extra, temp_scale => 0 }) {
    overrides($entry);
    @warnings = ();
    is(scalar keys %{poll({})}, 2, 'invalid definitions do not affect valid sources');
    ok(@warnings, 'invalid definitions are diagnosed');
}
write_file("$dir/outside", "123\n");
symlink "$dir/outside", "$root/class/extra/escape" or die $!;
overrides({ %$extra, path => '/sys/class/extra/escape' });
is(scalar keys %{poll(\%cache)}, 2, 'symlinks cannot escape sysfs');
write_file("$dir/overrides.json", '{"sources":');
@warnings = ();
is(scalar keys %{poll(\%cache)}, 2, 'malformed overrides leave defaults operational');
like(join('', @warnings), qr/invalid source list/, 'malformed JSON is diagnosed');

# The frontend consumes this real merged collector payload.
overrides($extra);
my $raw = {
    'fixture-chip' => { temp1 => { input => { value => 42, quantity => 'temperature', unit => 'C' } } },
};
write_file("$dir/sensors.json", encode_json($raw));
local $config{debug}{lm_sensors_mode} = 1;
local $config{debug}{lm_sensors_output_file} = "$dir/sensors.json";
local $config{lm_sensors}{enabled} = 1;
local $config{lm_sensors}{enable_other_temp} = 1;
local $config{system_info}{temp_unit} = 'C';
local $config{system_info}{ignore_temp_below} = 5;
my $payload_text = PVE::PVEMods::Collector::LmSensors::_get_temperature_sensors({});
my $payload = decode_json($payload_text);
is_deeply($payload->{enhanced_sensors}{'fixture-chip'}, $raw->{'fixture-chip'}, 'merging preserves lm-sensors data');
is(scalar keys %{$payload->{enhanced_sensors}}, 4, 'collector publishes all sources in the same JSON');
write_file("$ENV{LM_SENSORS_PAYLOADS}/sysfs-merged.json", $payload_text);
local $config{lm_sensors}{enabled} = 0;
my $disabled = decode_json(PVE::PVEMods::Collector::LmSensors::_get_temperature_sensors({}));
is_deeply($disabled->{enhanced_sensors}, $raw, 'sysfs collection requires lm-sensors collection to be enabled');

open my $counter, '|-', 'bash', '-c', 'source "$1"; detect_sensor_counts > "$2"',
    'bash', "$Bin/../../src/modules/node_info/node_info.configure.sh", "$dir/counts" or die $!;
print {$counter} encode_json($payload->{enhanced_sensors});
close $counter or die "wizard count failed: $?";
open my $counts, '<', "$dir/counts" or die $!;
my @counts = split /\t/, <$counts>;
close $counts;
is($counts[4], 4, 'wizard includes additional temperature sources');
like($counts[10], qr/Test <sensor>&/, 'wizard uses friendly source labels');
done_testing();
