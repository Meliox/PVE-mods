use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use POSIX ();
use Time::HiRes qw(sleep);

use lib "$ENV{NODE_INFO_TEST_ROOT}/usr/share/perl5";
use PVE::PVEMods::Collector::LmSensors qw(collector_for_temperature_sensors);
use PVE::PVEMods::Config qw(%config);

my $FIXTURE = "$ENV{LM_SENSORS_FIXTURES}/01-synthetic-reference.json";
my $dir = tempdir(CLEANUP => 1);
sub write_file {
    my ($path, $value) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $value;
    close $fh or die "$path: $!";
}
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return scalar <$fh>;
}

my $sanitize = \&PVE::PVEMods::Collector::LmSensors::_sanitize_sensors;
my $ram      = \&PVE::PVEMods::Collector::LmSensors::_get_ram_info;
my $drives   = \&PVE::PVEMods::Collector::LmSensors::_get_drive_names;
my $cpus     = \&PVE::PVEMods::Collector::LmSensors::_get_cpu_name;
my $pipeline = \&PVE::PVEMods::Collector::LmSensors::_get_temperature_sensors;

# ---- Sanitizing raw `sensors -J` output ------------------------------------
{
    my $out = $sanitize->(qq({"chip":{"unit":"\\u00b0C","other":"\\ufffdF"}}));
    is_deeply(decode_json($out), { chip => { unit => 'C', other => 'F' } },
        'escaped degree signs and replacement characters are stripped before the unit');
    like($sanitize->("\xC2\xB0C and \xB0F and \x{00B0}C and \x{FFFD}F"), qr/^C and F and C and F$/,
        'raw degree sign byte sequences are stripped as well');
    is($sanitize->('"label": "20 degrees"'), '"label": "20 degrees"', 'text without a degree sign is untouched');
}
{
    my $raw = join("\n",
        '{',
        '  "nct6775-isa-0290": {',
        '    "Adapter": "ISA adapter",',
        "    ERROR: Can't get value of subfeature temp3_input: Can't read",
        '    "fan1": { "fan1_input": 1200.0 }',
        '  }',
        '}',
        '');
    my $data = decode_json($sanitize->($raw));
    is($data->{'nct6775-isa-0290'}{temp3_input}, 0, 'unreadable subfeature becomes a zero reading');
    is($data->{'nct6775-isa-0290'}{fan1}{fan1_input}, 1200, 'neighbouring readings survive');

    my $bang = $sanitize->(qq({\n  "chip": {\n    ERROR: Kernel driver error temp2_input!\n    "temp1_input": 1.0\n  }\n}\n));
    is(decode_json($bang)->{chip}{temp2_input}, 0, 'error line ending in "!" becomes a zero reading');
}
is_deeply(decode_json($sanitize->('{"a": {"b": 1, }, "c": [1, 2]}')), { a => { b => 1 }, c => [1, 2] },
    'trailing commas before a closing brace are removed');
{
    my $out = $sanitize->('{"chip": {"temp1": {"alarm": NaN}, "label": "NaNa"}}');
    my $data = decode_json($out);
    ok(!defined $data->{chip}{temp1}{alarm}, 'NaN reading becomes null');
    is($data->{chip}{label}, 'NaNa', 'NaN replacement only touches whole words');
}

# ---- DIMM normalisation ----------------------------------------------------
sub temp_feature { return { input => { value => $_[0], quantity => 'temperature', unit => 'C' } } }
{
    my $input = JSON::PP->new->canonical->encode({
        'spd5118-i2c-1-50' => { Adapter => 'SMBus', temp1 => temp_feature(41.5) },
        'spd5118-i2c-1-57' => { Adapter => 'SMBus', temp1 => temp_feature(40) },
        'spd5118-i2c-0-5a' => { Adapter => 'SMBus', temp1 => temp_feature(39) },
        'coretemp-isa-0000' => { temp1 => temp_feature(50) },
    });
    my $data = decode_json($ram->($input));
    is($data->{DIMM1}{dimm_slot}, 1, 'address 0x50 maps to slot 1');
    is($data->{DIMM8}{dimm_slot}, 8, 'address 0x57 maps to slot 8');
    is($data->{DIMM3}{dimm_slot}, 3, 'slot is derived from the low address bits');
    is($data->{DIMM1}{source}, 'spd5118', 'source is recorded');
    is($data->{DIMM1}{bus}, 1, 'I2C bus is recorded as a number');
    is($data->{DIMM1}{address}, '50', 'I2C address is recorded');
    is($data->{DIMM1}{temp1}{input}{value}, 41.5, 'temperature feature is kept under temp1');
    ok(!grep({ /^spd5118-/ } keys %$data), 'raw spd5118 chip entries are removed');
    ok(exists $data->{'coretemp-isa-0000'}, 'unrelated chips are untouched');
}
is($ram->('not json'), 'not json', 'invalid JSON is returned unchanged by the DIMM step');
{
    my $input = JSON::PP->new->canonical->encode({
        'spd5118-i2c-1-52' => { temp1 => temp_feature(44) },
        'jc42-i2c-0-1a'    => { Adapter => 'SMBus', temp1 => temp_feature(36) },
        'jc42-i2c-0-1c'    => { temp1 => temp_feature(37) },
        'jc42-i2c-0-1b'    => { fan1 => { input => { value => 1 } } },
    });
    my $data = decode_json($ram->($input));
    is($data->{DIMM3}{source}, 'spd5118', 'spd5118 wins when a jc42 chip claims the same slot');
    is($data->{DIMM3}{temp1}{input}{value}, 44, 'the spd5118 reading is the one kept for a contested slot');
    is($data->{DIMM5}{source}, 'jc42', 'jc42 chips are DIMM entries too');
    is($data->{DIMM5}{dimm_slot}, 5, 'jc42 address 0x1c maps to slot 5');
    is($data->{DIMM5}{bus}, 0, 'jc42 I2C bus is recorded');
    is($data->{DIMM5}{address}, '1c', 'jc42 I2C address is recorded');
    is($data->{DIMM5}{temp1}{input}{value}, 37, 'jc42 temperature feature is kept under temp1');
    ok(!grep({ /^jc42-/ && !/-0-1b$/ } keys %$data), 'promoted jc42 chips are removed');
    ok(exists $data->{'jc42-i2c-0-1b'}, 'a jc42 chip without a temperature is left alone');
}
{
    my $dell = {
        'dell_smm-isa-0000' => {
            Adapter => 'ISA adapter',
            fan1  => { label => 'Processor Fan', input => { value => 995 } },
            temp1 => { label => 'CPU', input => { value => 40 } },
            temp3 => { label => 'SODIMM', input => { value => 25 }, max => { value => 85 } },
            temp4 => { label => 'SODIMM', input => { value => 33 } },
            temp6 => { label => 'SODIMM 2', input => { value => 24 } },
            temp7 => { label => 'Dimm A1', input => { value => 30 } },
            temp8 => { label => 'DIMM', input => 'broken' },
            temp9 => { input => { value => 50 } },
        },
        'spd5118-i2c-1-50' => { temp1 => temp_feature(41) },
    };
    my $data = decode_json($ram->(JSON::PP->new->canonical->encode($dell)));
    is_deeply([sort grep { /^DIMM/ } keys %$data], [qw(DIMM1 DIMM2 DIMM3 DIMM4 DIMM7 DIMM8)],
        'labelled temperatures become DIMM entries');
    is($data->{DIMM3}{temp1}{input}{value}, 25, 'the sensor number is the slot when the label has none');
    is($data->{DIMM3}{temp1}{max}{value}, 85, 'thresholds travel with the reading');
    is($data->{DIMM4}{temp1}{input}{value}, 33, 'repeated labels stay separate, one slot each');
    is($data->{DIMM2}{temp1}{input}{value}, 24, 'a number at the end of the label is the slot');
    is($data->{DIMM7}{temp1}{input}{value}, 30, 'a channel/slot label such as "Dimm A1" falls back to the sensor number');
    is($data->{DIMM8}{temp1}{input}, 'broken', 'an unreadable labelled feature is carried over as it is');
    is($data->{DIMM4}{source}, 'label', 'the source records that the slot came from a label');
    is($data->{DIMM1}{source}, 'spd5118', 'spd5118 keeps slot 1');
    ok(!exists $data->{DIMM1}{temp1}{label}, 'the spd5118 entry is not mixed with labelled ones');
    is_deeply([sort grep { /^temp\d+$/ } keys %{ $data->{'dell_smm-isa-0000'} }], [qw(temp1 temp9)],
        'promoted features leave their chip; other temperatures stay');
    is($data->{'dell_smm-isa-0000'}{fan1}{input}{value}, 995, 'other features of the chip are untouched');
}
{
    my $input = JSON::PP->new->canonical->encode({
        'spd5118-i2c-1-50' => { temp1 => temp_feature(41) },
        'dell_smm-isa-0000' => { temp1 => { label => 'SODIMM 1', input => { value => 99 } } },
    });
    my $data = decode_json($ram->($input));
    is($data->{DIMM1}{temp1}{input}{value}, 41, 'a chip beats a label when both claim a slot');
    ok(!exists $data->{'dell_smm-isa-0000'}{temp1}, 'the losing labelled feature is still removed from its chip');
}
is_deeply(decode_json($ram->(JSON::PP->new->encode({ cpu => { temp1 => { label => 'CPU', input => { value => 1 } } } }))),
    { cpu => { temp1 => { label => 'CPU', input => { value => 1 } } } }, 'labels without DIMM leave the document unchanged');
is_deeply(decode_json($ram->('{}')), {}, 'no DIMM entries leaves an empty document');

# ---- Drive enrichment ------------------------------------------------------
{
    my $input = JSON::PP->new->canonical->encode({
        'drivetemp-scsi-0-0' => { temp1 => temp_feature(34) },
        'nvme-pci-0600'      => { temp1 => temp_feature(39) },
        'coretemp-isa-0000'  => { temp1 => temp_feature(50) },
    });
    my %cache = (
        'drivetemp-scsi-0-0' => { device_path => '/dev/sda', model => 'Test SSD', serial => 'SER1' },
        'nvme-pci-0600'      => { device_path => '/dev/nvme0n1', model => 'Test NVMe', serial => 'SER2' },
    );
    my $data = decode_json($drives->($input, \%cache));
    is($data->{'drivetemp-scsi-0-0'}{model}, 'Test SSD', 'cached model is applied to SATA drives');
    is($data->{'drivetemp-scsi-0-0'}{serial}, 'SER1', 'cached serial is applied');
    is($data->{'drivetemp-scsi-0-0'}{device_path}, '/dev/sda', 'cached device path is applied');
    is($data->{'nvme-pci-0600'}{model}, 'Test NVMe', 'cached model is applied to NVMe drives');
    ok(!exists $data->{'coretemp-isa-0000'}{model}, 'non-drive chips are not enriched');
}
{
    # Devices that do not exist on the host fall back to "unknown" and are cached.
    my $input = JSON::PP->new->canonical->encode({
        'drivetemp-scsi-99-99' => { temp1 => temp_feature(30) },
        'drivetemp-nvme-9999'  => { temp1 => temp_feature(31) },
        'nvme-pci-fe0e'        => { temp1 => temp_feature(32) },
    });
    my %cache;
    my $data = decode_json($drives->($input, \%cache));
    for my $chip (sort keys %$data) {
        is($data->{$chip}{model}, 'unknown', "$chip: missing device has an unknown model");
        is($data->{$chip}{serial}, 'unknown', "$chip: missing device has an unknown serial");
        is($data->{$chip}{device_path}, $chip =~ /^drivetemp-nvme/ ? '/dev/nvme9999n1' : 'unknown',
            "$chip: device path falls back sensibly");
    }
    is(scalar(keys %cache), 3, 'lookups are cached per chip');
    my $again = decode_json($drives->($input, \%cache));
    is_deeply($again, $data, 'cached lookup returns the same result');
}
is($drives->('not json', {}), 'not json', 'invalid JSON is returned unchanged by the drive step');
{
    my $data = decode_json($drives->('{"x":{"y":1}}'));
    is_deeply($data, { x => { y => 1 } }, 'the cache argument is optional');
}

# ---- CPU enrichment --------------------------------------------------------
{
    my $input = JSON::PP->new->canonical->encode({
        'coretemp-isa-0000'    => { temp1 => temp_feature(50) },
        'k10temp-pci-00c3'     => { temp1 => temp_feature(51) },
        'cpu_thermal-virtual-0' => { temp1 => temp_feature(52) },
        'nct6775-isa-0290'     => { temp1 => temp_feature(30) },
    });
    my %cache = (
        'coretemp-isa-0000'     => { model => 'Intel(R) Test CPU', package => 0 },
        'k10temp-pci-00c3'      => { model => 'AMD Test CPU', package => 1 },
        'cpu_thermal-virtual-0' => { model => 'Test Board', package => 0 },
    );
    my $data = decode_json($cpus->($input, \%cache));
    is($data->{'coretemp-isa-0000'}{cpu_model}, 'Intel(R) Test CPU', 'Intel CPU model is applied');
    is($data->{'coretemp-isa-0000'}{cpu_package}, 0, 'Intel CPU package is applied');
    is($data->{'k10temp-pci-00c3'}{cpu_model}, 'AMD Test CPU', 'AMD CPU model is applied');
    is($data->{'k10temp-pci-00c3'}{cpu_package}, 1, 'AMD CPU package is applied');
    is($data->{'cpu_thermal-virtual-0'}{cpu_model}, 'Test Board', 'Raspberry Pi model is applied');
    ok(!exists $data->{'nct6775-isa-0290'}{cpu_model}, 'other chips are not enriched');
}
{
    my %cache;
    my $data = decode_json($cpus->('{"cpu_thermal-virtual-0":{"temp1":{}}}', \%cache));
    ok(length $data->{'cpu_thermal-virtual-0'}{cpu_model}, 'Raspberry Pi falls back to a non-empty model name');
    is($data->{'cpu_thermal-virtual-0'}{cpu_package}, 0, 'Raspberry Pi is package 0');
    ok(exists $cache{'cpu_thermal-virtual-0'}, 'CPU lookups are cached');
}
is($cpus->('not json', {}), 'not json', 'invalid JSON is returned unchanged by the CPU step');

# ---- Full pipeline (debug fixture) -----------------------------------------
my %primed = (
    'coretemp-isa-0000'  => { model => 'Intel(R) Test CPU', package => 0 },
    'drivetemp-scsi-0-0' => { device_path => '/dev/sda', model => 'Test SSD', serial => 'SER1' },
    'nvme-pci-0600'      => { device_path => '/dev/nvme0n1', model => 'Test NVMe', serial => 'SER2' },
);
{
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $FIXTURE;
    local $config{lm_sensors}{enable_cpu} = 1;
    local $config{lm_sensors}{enable_ram_temp} = 0;
    local $config{lm_sensors}{enable_nvme_temp} = 1;
    local $config{lm_sensors}{enable_fan_speed} = 0;
    local $config{lm_sensors}{display_zero_speed_fans} = 1;
    local $config{lm_sensors}{enable_hdd_temp} = 0;
    local $config{lm_sensors}{enable_other_temp} = 1;
    local $config{system_info}{temp_unit} = 'F';
    local $config{system_info}{ignore_temp_below} = '7';

    my %cache = %primed;
    my $payload = decode_json($pipeline->(\%cache));
    ok($payload->{cpu}, 'cpu flag follows the configuration');
    ok(!$payload->{ram}, 'ram flag follows the configuration');
    ok($payload->{nvme}, 'nvme flag follows the configuration');
    ok(!$payload->{fans}, 'fans flag follows the configuration');
    ok(!$payload->{hdd}, 'hdd flag follows the configuration');
    ok($payload->{other}, 'other flag follows the configuration');
    ok($payload->{display_zero_speed_fans}, 'zero speed fans flag follows the configuration');
    is($payload->{temp_unit}, 'F', 'temperature unit is passed through');
    is($payload->{ignore_temp_below}, 7, 'ignore threshold is numeric');
    ok(JSON::PP::is_bool($payload->{cpu}), 'flags are JSON booleans');

    my $sensors = $payload->{enhanced_sensors};
    is($sensors->{'coretemp-isa-0000'}{cpu_model}, 'Intel(R) Test CPU', 'CPU model is merged into the payload');
    is($sensors->{'drivetemp-scsi-0-0'}{model}, 'Test SSD', 'drive model is merged into the payload');
    is($sensors->{'nvme-pci-0600'}{serial}, 'SER2', 'NVMe serial is merged into the payload');
    is($sensors->{DIMM1}{dimm_slot}, 1, 'DIMM 1 is normalised in the payload');
    is($sensors->{DIMM2}{temp1}{input}{value}, 43.25, 'DIMM 2 keeps its reading');
    ok(!grep({ /^spd5118-/ } keys %$sensors), 'raw spd5118 chips are not in the payload');
    is($sensors->{'nct6775-isa-0290'}{fan1}{label}, 'CPU Fan', 'fan labels are preserved');
}
{
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $FIXTURE;
    local $config{lm_sensors}{$_} = 0 for qw(enable_cpu enable_ram_temp enable_nvme_temp enable_fan_speed
        display_zero_speed_fans enable_hdd_temp enable_other_temp);
    my $payload = decode_json($pipeline->({%primed}));
    ok(!$payload->{$_}, "$_ is false when disabled") for qw(cpu ram nvme fans hdd other display_zero_speed_fans);
    ok(exists $payload->{enhanced_sensors}{DIMM1}, 'sensor data is still collected for the GUI to filter');
}
{
    my $empty = "$dir/empty.json";
    write_file($empty, '{}');
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $empty;
    is_deeply(decode_json($pipeline->({}))->{enhanced_sensors}, {}, 'an empty sensors document yields an empty payload');
}
{
    my $broken = "$dir/broken.json";
    write_file($broken, '{"chip": {"temp1_input": ');
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $broken;
    my $out = $pipeline->({});
    is($out, '{"chip": {"temp1_input": ', 'unparseable output is passed through rather than dying');
}
{
    my $unreadable = "$dir/unreadable.json";
    write_file($unreadable, JSON::PP->new->canonical->encode({ 'coretemp-isa-0000' => {
        temp1 => { label => 'Package id 0', input => { quantity => 'temperature', unit => 'C', value => 52 } },
        temp2 => { label => 'Core 0', input => { quantity => 'temperature', unit => 'C', value => 48 } },
    } }) =~ s/"value":48\}/"value":48},"alarm":NaN/r);
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $unreadable;
    my $sensors = decode_json($pipeline->({%primed}))->{enhanced_sensors};
    is($sensors->{'coretemp-isa-0000'}{temp1}{input}{value}, 52, 'readings in the sensors -J layout are kept');
    ok(exists $sensors->{'coretemp-isa-0000'}{temp2}{alarm} && !defined $sensors->{'coretemp-isa-0000'}{temp2}{alarm},
        'a subfeature sensors could not read (NaN) becomes null');
}

# ---- Dell T7910 (Meliox/PVE-mods#73), as sensors -J prints it --------------
# The hardware has repeated labels (four SODIMM, two Processor Fan, two CPU). sensors -J keys
# features by their unique names (temp3, fan1, ...), so none of them can be lost.
{
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = "$ENV{LM_SENSORS_FIXTURES}/03-dell-t7910-dual-xeon.json";
    my %cache = (
        'coretemp-isa-0000' => { model => 'Intel(R) Test CPU', package => 0 },
        'coretemp-isa-0001' => { model => 'Intel(R) Test CPU', package => 1 },
    );
    my $sensors = decode_json($pipeline->(\%cache))->{enhanced_sensors};
    is_deeply([sort grep { /^coretemp/ } keys %$sensors], [qw(coretemp-isa-0000 coretemp-isa-0001)],
        'both CPU packages are reported');
    is($sensors->{'coretemp-isa-0001'}{temp1}{label}, 'Package id 1', 'package label is kept');
    is($sensors->{'coretemp-isa-0001'}{temp1}{input}{value}, 45, 'package temperature is kept');
    is(scalar(grep { ref $_ eq 'HASH' && ($_->{label} // '') =~ /^Core \d+$/ } values %{ $sensors->{'coretemp-isa-0000'} }), 6,
        'all six cores are kept');
    is($sensors->{'coretemp-isa-0000'}{cpu_package}, 0, 'CPU enrichment is applied');

    my $dell = $sensors->{'dell_smm-isa-0000'};
    is_deeply([map { $dell->{$_}{input}{value} } qw(fan1 fan2 fan3)], [995, 994, 600], 'all three fans are kept');
    is_deeply([map { $dell->{$_}{label} } qw(fan1 fan2 fan3)], ['Processor Fan', 'Processor Fan', 'Other Fan'],
        'repeated fan labels stay separate features');
    is_deeply([map { $dell->{$_}{input}{value} } qw(temp1 temp2)], [40, 45], 'both CPU sensors are kept');
    # The settings wizard classifies chips by "SODIMM"/"DIMM" feature labels, so the collector
    # promotes those temperatures to DIMM entries and removes them from their chip.
    my @dimms = sort grep { /^DIMM\d+$/ } keys %$sensors;
    is_deeply(\@dimms, [qw(DIMM3 DIMM4 DIMM5 DIMM6)], 'the four SODIMMs are reported as DIMM entries');
    is_deeply([map { $sensors->{$_}{temp1}{input}{value} } @dimms], [25, 33, 33, 24], 'each SODIMM keeps its own reading');
    is_deeply([map { $sensors->{$_}{temp1}{label} } @dimms], [('SODIMM') x 4], 'the SODIMM labels are kept');
    is_deeply([sort grep { /^temp\d+$/ } keys %$dell], [qw(temp1 temp2)], 'the CPU temperatures stay in the dell_smm chip');
    is_deeply([map { $dell->{$_}{input}{value} } qw(fan1 fan2 fan3)], [995, 994, 600], 'the fans stay in the dell_smm chip');
}

# ---- Every fixture -----------------------------------------------------------
# fixtures/lm_sensors/NN-*.json, described in test-lm-sensors.sh. Drop another capture in as the
# next NN-*.json and it is covered here and in the GUI tests.

# Keep in sync with the cache built in lm-sensors-payload.pl
sub primed_cache {
    my ($chips) = @_;
    my %cache;
    for my $chip (keys %$chips) {
        if ($chip =~ /^(?:coretemp-isa-|k10temp-pci-|cpu_thermal-virtual-)/) {
            my ($package) = $chip =~ /^coretemp-isa-(\d+)$/;
            $cache{$chip} = { model => 'Intel(R) Core(TM) Test <CPU>', package => ($package // 0) + 0 };
        } elsif ($chip =~ /^drivetemp-/) {
            $cache{$chip} = { device_path => '/dev/sda', model => 'Test SSD', serial => 'SER123' };
        } elsif ($chip =~ /^nvme-pci-/) {
            $cache{$chip} = { device_path => '/dev/nvme0n1', model => 'Test NVMe', serial => 'NVME456' };
        }
    }
    return \%cache;
}

# Readings in either layout: tempN_input style keys, or {input => {value => ...}} features
sub count_readings {
    my ($node) = @_;
    return 0 unless ref $node eq 'HASH';
    my $count = 0;
    for my $key (keys %$node) {
        my $value = $node->{$key};
        $count++ if $key =~ /_input$/ && !ref $value;
        $count++ if $key eq 'input' && ref $value eq 'HASH' && exists $value->{value};
        $count += count_readings($value) if ref $value eq 'HASH';
    }
    return $count;
}
sub raw_readings {
    my ($text) = @_;
    return scalar(() = $text =~ /"[A-Za-z0-9_]*_input"\s*:|"input"\s*:\s*\{/g);
}

my @fixtures = sort glob("$ENV{LM_SENSORS_FIXTURES}/[0-9][0-9]-*.json");
cmp_ok(scalar @fixtures, '>=', 11, 'fixtures are available');
for my $file (@fixtures) {
    my ($name) = $file =~ m{([^/]+)\.json$};
    my $raw = slurp($file);
    my $chips = decode_json($raw);

    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $file;
    local $config{lm_sensors}{$_} = 1 for qw(enable_cpu enable_ram_temp enable_hdd_temp enable_nvme_temp
        enable_fan_speed display_zero_speed_fans enable_other_temp);
    my $out = $pipeline->(primed_cache($chips));
    my $payload = eval { decode_json($out) };
    ok($payload && ref $payload->{enhanced_sensors} eq 'HASH', "$name: pipeline produces a payload") or next;
    my $sensors = $payload->{enhanced_sensors};

    is_deeply([sort grep { !/^(?:spd5118|jc42)-/ } keys %$chips],
        [sort grep { !/^DIMM/ } keys %$sensors], "$name: every chip is reported");
    # RAM comes from spd5118/jc42 chips and from temperatures labelled DIMM on other chips
    my @ram_chips = grep { /^(?:spd5118|jc42)-/ } keys %$chips;
    my $labelled_features = 0;
    for my $chip (grep { !/^(?:spd5118|jc42)-/ } keys %$chips) {
        next unless ref $chips->{$chip} eq 'HASH';
        $labelled_features += grep { ref $chips->{$chip}{$_} eq 'HASH' && ($chips->{$chip}{$_}{label} // '') =~ /DIMM/i }
            grep { /^temp\d+$/ } keys %{ $chips->{$chip} };
    }
    is(scalar(grep { /^DIMM\d+$/ } keys %$sensors), scalar(@ram_chips) + $labelled_features,
        "$name: one DIMM entry per RAM sensor");
    ok(!grep({ /^(?:spd5118|jc42)-/ } keys %$sensors), "$name: raw RAM chips are replaced");
    is(scalar(grep { my $c = $sensors->{$_}; !/^DIMM/ && ref $c eq 'HASH'
        && grep { ref $c->{$_} eq 'HASH' && ($c->{$_}{label} // '') =~ /DIMM/i } keys %$c } keys %$sensors), 0,
        "$name: no DIMM temperature is left on another chip");
    is(count_readings($sensors), count_readings($chips), "$name: the pipeline keeps every parsed reading");
    for my $chip (grep { /^(?:coretemp-isa-|k10temp-pci-)/ } keys %$sensors) {
        is($sensors->{$chip}{cpu_model}, 'Intel(R) Core(TM) Test <CPU>', "$name: $chip is enriched with the CPU model");
    }
    for my $chip (grep { /^(?:drivetemp-|nvme-pci-)/ } keys %$sensors) {
        like($sensors->{$chip}{model}, qr/^Test /, "$name: $chip is enriched with the drive model");
    }

    # sensors -J keys features by their unique names, so no reading can be overwritten when
    # the text is read as JSON: every reading in the raw output is in the parsed document.
    is(raw_readings($raw), count_readings($chips), "$name: no readings are lost to duplicate keys");
}

{
    my $file = "$ENV{LM_SENSORS_FIXTURES}/09-amd-ddr5-nvme.json";
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $file;
    my $sensors = decode_json($pipeline->(primed_cache(decode_json(slurp($file)))))->{enhanced_sensors};
    is($sensors->{DIMM1}{source}, 'spd5118', 'AMD/DDR5: the spd5118 module becomes DIMM1');
    is($sensors->{DIMM1}{bus}, 1, 'AMD/DDR5: the I2C bus is taken from the chip name');
    is($sensors->{DIMM1}{temp1}{input}{value}, 48.5, 'AMD/DDR5: the DIMM reading is kept');
    is($sensors->{'k10temp-pci-00c3'}{temp1}{label}, 'Tctl', 'AMD/DDR5: k10temp keeps its Tctl label');
    is($sensors->{'k10temp-pci-00c3'}{temp1}{input}{value}, 51.125, 'AMD/DDR5: k10temp keeps its Tctl reading');
    is($sensors->{'k10temp-pci-00c3'}{cpu_package}, 0, 'AMD/DDR5: k10temp is enriched');
    is($sensors->{'amdgpu-pci-6500'}{temp1}{input}{value}, 45, 'AMD/DDR5: GPU readings are left alone');
}
{
    my $file = "$ENV{LM_SENSORS_FIXTURES}/02-intel-it8620-ddr5-nvme.json";
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $file;
    my $sensors = decode_json($pipeline->(primed_cache(decode_json(slurp($file)))))->{enhanced_sensors};
    is($sensors->{DIMM1}{temp1}{input}{value}, 43.5, 'sensors -J: the DDR5 reading is kept in the new layout');
    is($sensors->{DIMM1}{bus}, 0, 'sensors -J: the I2C bus is taken from the chip name');
    is($sensors->{'coretemp-isa-0000'}{temp9}{label}, 'Core 7', 'sensors -J: labels are kept');
    is($sensors->{'coretemp-isa-0000'}{temp1}{input}{value}, 52, 'sensors -J: the degree sign in the unit does not break parsing');
    is($sensors->{'it8620-isa-0a20'}{temp1}{input}{value}, -128, 'sensors -J: disconnected sensors keep their -128 reading');
    is($sensors->{'it8620-isa-0a20'}{fan3}{input}{value}, 0, 'sensors -J: a stopped fan keeps its zero reading');
    is($sensors->{'it8620-isa-0a20'}{temp2}{type}{label}, 'thermistor', 'sensors -J: entries without a quantity are kept');
    is($sensors->{'nvme-pci-0600'}{temp1}{input}{value}, 41.85, 'sensors -J: NVMe composite temperature is kept');
    is($sensors->{'nvme-pci-0600'}{model}, 'Test NVMe', 'sensors -J: NVMe model is merged');
}
{
    # The error `sensors` prints for an unreadable alarm; it is written to stderr, which the
    # live command discards, but the sanitizer still turns it into a zero reading.
    my $line = "ERROR: Can't get value of subfeature temp1_max_alarm: Can't read\n";
    is($sanitize->($line), qq("temp1_max_alarm": 0.000,\n), 'unreadable alarm becomes a zero reading');
}
{
    my $file = "$ENV{LM_SENSORS_FIXTURES}/10-raspberry-pi5-2-nvme.json";
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $file;
    my $sensors = decode_json($pipeline->(primed_cache(decode_json(slurp($file)))))->{enhanced_sensors};
    is($sensors->{'cpu_thermal-virtual-0'}{temp1}{input}{value}, 45.2, 'Raspberry Pi 5: the SoC temperature is kept');
    is($sensors->{'cpu_thermal-virtual-0'}{cpu_package}, 0, 'Raspberry Pi 5: the SoC is enriched as package 0');
    ok(length $sensors->{'cpu_thermal-virtual-0'}{cpu_model}, 'Raspberry Pi 5: the SoC gets a model name');
    is($sensors->{'rp1_adc-isa-0000'}{temp1}{input}{value}, 51.985, 'Raspberry Pi 5: the RP1 I/O controller temperature is kept');
    is($sensors->{'nvme-pci-10600'}{temp1}{label}, 'Composite', 'Raspberry Pi 5: NVMe on a long PCI address keeps its labels');
    is($sensors->{'nvme-pci-10600'}{temp1}{input}{value}, 32.85, 'Raspberry Pi 5: NVMe on a long PCI address is kept');
    is($sensors->{'nvme-pci-10600'}{model}, 'Test NVMe', 'Raspberry Pi 5: NVMe on a long PCI address is enriched');
    is($sensors->{'nvme-pci-10400'}{temp9}{label}, 'Sensor 8', 'Raspberry Pi 5: sensors are keyed by their feature number');
    is($sensors->{'nvme-pci-10400'}{temp9}{input}{value}, 29.85, 'Raspberry Pi 5: extra NVMe sensors are kept');
    is($sensors->{'nvme-pci-10600'}{temp2}{max}{value}, 65261.85, 'Raspberry Pi 5: implausible thresholds are passed through');
    is($sensors->{'pwmfan-isa-0000'}{fan1}{input}{value}, 0, 'Raspberry Pi 5: a stopped fan keeps its zero reading');
}
{
    my $file = "$ENV{LM_SENSORS_FIXTURES}/04-dell-smm-sodimm.json";
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $file;
    my $sensors = decode_json($pipeline->(primed_cache(decode_json(slurp($file)))))->{enhanced_sensors};
    is($sensors->{DIMM6}{temp1}{label}, 'SODIMM', 'Dell: the SODIMM label is kept');
    is($sensors->{DIMM6}{temp1}{input}{value}, 38, 'Dell: the SODIMM is shown as DIMM6');
    is($sensors->{DIMM6}{dimm_slot}, 6, 'Dell: the slot is the sensor number');
    ok(!exists $sensors->{'dell_smm-isa-00de'}{temp6}, 'Dell: the SODIMM is no longer listed under the chip');
    is($sensors->{'dell_smm-isa-00de'}{temp2}{label}, 'CPU', 'Dell: the CPU temperature stays in the chip');
}

# ---- Collector loop --------------------------------------------------------
{
    my $work = tempdir(CLEANUP => 1);
    my $state = "$work/sensors.json";
    local $PVE::PVEMods::Collector::LmSensors::sensors_state_file = $state;
    local $config{debug}{lm_sensors_mode} = 1;
    local $config{debug}{lm_sensors_output_file} = $FIXTURE;
    local $config{lm_sensors}{enable_ram_temp} = 1;
    local $config{intervals}{data_pull} = 1;

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        collector_for_temperature_sensors({});
        POSIX::_exit(1);
    }
    for (1..100) {
        last if -s $state;
        sleep 0.05;
    }
    ok(-s $state, 'collector publishes the sensors state file');
    if (-s $state) {
        my $payload = decode_json(slurp($state));
        ok($payload->{ram}, 'published payload carries the configured flags');
        is($payload->{enhanced_sensors}{DIMM1}{temp1}{input}{value}, 41.5, 'published payload carries normalised readings');
    }
    kill 'TERM', $pid;
    waitpid($pid, 0);
    is($? >> 8, 0, 'collector handles SIGTERM cleanly');
}
done_testing();
