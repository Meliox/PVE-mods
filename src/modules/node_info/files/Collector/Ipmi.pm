package PVE::PVEMod::Collector::Ipmi;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use File::Temp qw(tempfile);
use JSON::PP;

our @EXPORT_OK = qw(parse_sensor_output parse_dcmi_output collect_once write_snapshot);

my $IPMITOOL = '/usr/bin/ipmitool';
my $TIMEOUT = '/usr/bin/timeout';

sub _trim {
    my ($value) = @_;
    $value //= '';
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _number {
    my ($value) = @_;
    $value = _trim($value);
    return undef unless $value =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/;
    return 0 + $value;
}

sub parse_sensor_output {
    my ($output) = @_;
    my @sensors;
    my %units = (
        'degrees c' => ['temperature', '°C'],
        'rpm'       => ['fan', 'RPM'],
        'volts'     => ['voltage', 'V'],
        'watts'     => ['power', 'W'],
    );
    my @threshold_names = qw(
        lower_non_recoverable lower_critical lower_non_critical
        upper_non_critical upper_critical upper_non_recoverable
    );

    for my $line (split /\r?\n/, $output // '') {
        next unless index($line, '|') >= 0;
        my @fields = map { _trim($_) } split /\|/, $line, -1;
        next unless @fields >= 4 && length($fields[0]);

        my ($name, $raw_reading, $raw_unit, $status) = @fields[0..3];
        my $unit_info = $units{lc $raw_unit};
        my %thresholds;
        for my $i (0..$#threshold_names) {
            $thresholds{$threshold_names[$i]} = _number($fields[$i + 4]);
        }

        my $value = _number($raw_reading);
        push @sensors, {
            name       => $name,
            category   => $unit_info ? $unit_info->[0] : 'other',
            unit       => $unit_info ? $unit_info->[1] : $raw_unit,
            raw_unit   => $raw_unit,
            value      => $value,
            available  => defined($value) ? JSON::PP::true : JSON::PP::false,
            status     => $status,
            thresholds => \%thresholds,
        };
    }

    return \@sensors;
}

sub parse_dcmi_output {
    my ($output) = @_;
    return undef unless defined $output;

    my %patterns = (
        instantaneous_watts => qr/Instantaneous power reading:\s*([\d.]+)\s*(?:Watts?|W)\b/i,
        minimum_watts       => qr/Minimum during sampling period:\s*([\d.]+)\s*(?:Watts?|W)\b/i,
        maximum_watts       => qr/Maximum during sampling period:\s*([\d.]+)\s*(?:Watts?|W)\b/i,
        average_watts       => qr/Average power reading over sample period:\s*([\d.]+)\s*(?:Watts?|W)\b/i,
        sampling_seconds    => qr/Sampling period:\s*([\d.]+)\s*Seconds?\b/i,
    );
    my %data;
    for my $key (keys %patterns) {
        $data{$key} = _number($1) if $output =~ $patterns{$key};
    }
    return undef unless defined $data{instantaneous_watts};

    $data{state} = _trim($1) if $output =~ /Power reading state is:\s*([^\r\n]+)/i;
    $data{available} = (!defined($data{state}) || lc($data{state}) eq 'activated')
        ? JSON::PP::true : JSON::PP::false;
    return \%data;
}

sub _run_ipmitool {
    my (@args) = @_;
    my @command = ($TIMEOUT, '-k', '2s', '10s', $IPMITOOL, '-I', 'open', @args);
    open my $fh, '-|', @command or die "Cannot start ipmitool: $!";
    local $/;
    my $output = <$fh> // '';
    my $ok = close $fh;
    return ($output, $ok ? 0 : ($? >> 8));
}

sub collect_once {
    my ($sensor_output, $sensor_exit) = _run_ipmitool('sensor');
    die "ipmitool sensor failed (exit $sensor_exit)" if $sensor_exit;
    my $sensors = parse_sensor_output($sensor_output);
    die "ipmitool sensor returned no parseable sensors" unless @$sensors;

    my ($dcmi_output, $dcmi_exit) = _run_ipmitool('dcmi', 'power', 'reading');
    my $dcmi = $dcmi_exit ? undef : parse_dcmi_output($dcmi_output);

    return {
        schema_version => 1,
        sampled_at     => time(),
        source         => 'local-openipmi',
        sensors        => $sensors,
        dcmi           => $dcmi,
        errors         => $dcmi_exit ? ["DCMI power reading unavailable (exit $dcmi_exit)"] : [],
    };
}

sub write_snapshot {
    my ($path, $data) = @_;
    my ($dir) = $path =~ m{^(.*)/[^/]+$};
    die "Invalid snapshot path" unless defined $dir && -d $dir;

    my ($fh, $tmp) = tempfile('.ipmi-XXXXXX', DIR => $dir, UNLINK => 0);
    eval {
        print {$fh} JSON::PP->new->utf8->canonical->encode($data)
            or die "Cannot write $tmp: $!";
        chmod 0644, $tmp or die "Cannot set permissions on $tmp: $!";
        close $fh or die "Cannot close $tmp: $!";
        rename $tmp, $path or die "Cannot replace $path: $!";
    };
    if ($@) {
        my $error = $@;
        close $fh if fileno($fh);
        unlink $tmp;
        die $error;
    }
    return 1;
}

1;
