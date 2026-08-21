package PVE::PVEMod::Collector::Ups;

use strict;
use warnings;
use Exporter 'import';

use JSON;

use PVE::PVEMod::Config qw(%config $process_type $ups_state_file);
use PVE::PVEMod::Utils  qw(debug setup_collector_signals);

our @EXPORT_OK = qw(
    collector_for_ups
);

# ============================================================================
# UPS — long-running collector
# ============================================================================

sub collector_for_ups {
    my ($device) = @_;
    $process_type = 'collector';
    $0 = "collector-ups-$device->{ups_name}";
    debug(__LINE__, "UPS collector started");

    my $shutdown = 0;
    setup_collector_signals("ups-$device->{ups_name}", \$shutdown);

    while (!$shutdown) {
        my $ups_data = _get_ups_status($device->{ups_name});

        eval {
            open my $ofh, '>', $ups_state_file
                or die "Failed to open $ups_state_file: $!";
            print $ofh $ups_data;
            close $ofh;
            debug(__LINE__, "Wrote UPS data to $ups_state_file");
        };
        if ($@) {
            debug(__LINE__, "Error writing UPS data: $@");
        }

        sleep $config{intervals}{data_pull} unless $shutdown;  
    }

    debug(__LINE__, "UPS collector shutting down");
    exit 0;
}

# ============================================================================
# UPS — status query
# ============================================================================

sub _get_ups_status {
    my ($ups_name) = @_;

    debug(__LINE__, "Collecting UPS status for $ups_name");

    my $output;
    if ($config{debug}{ups_mode} && -f $config{debug}{ups_output_file}) {
        debug(__LINE__, "Debug mode: reading UPS data from $config{debug}{ups_output_file}");
        open my $fh, '<', $config{debug}{ups_output_file}
            or do { debug(__LINE__, "Failed to open debug file $config{debug}{ups_output_file}: $!"); return encode_json({ error => "Failed to open debug file" }); };
        local $/;
        $output = <$fh>;
        close $fh;
    } else {
        $output = `/usr/bin/upsc $ups_name 2>/dev/null`;
    }

    unless (defined $output && length($output) > 0) {
        debug(__LINE__, "No output from upsc for $ups_name");
        return encode_json({ error => "No data from UPS $ups_name" });
    }

    my $ups_data = _parse_upsc_output($output);

    unless (keys %$ups_data) {
        debug(__LINE__, "No data received from upsc for $ups_name");
        return encode_json({ error => "No data from UPS $ups_name" });
    }

    return JSON->new->pretty->canonical->encode({ $ups_name => $ups_data });
}

# ============================================================================
# UPS — output parser
# ============================================================================

sub _parse_upsc_output {
    my ($output) = @_;

    my $ups_data = {};

    debug(__LINE__, "Parsing upsc output");

    eval {
        foreach my $line (split /\n/, $output) {
            next if $line =~ /^\s*$/;
            next if $line =~ /^Init SSL/;

            if ($line =~ /^([^:]+):\s*(.*)$/) {
                my ($key, $value) = ($1, $2);
                $key   =~ s/^\s+|\s+$//g;
                $value =~ s/^\s+|\s+$//g;

                # Coerce numeric values
                if ($value =~ /^-?\d+\.?\d*$/) {
                    $ups_data->{$key} = $value + 0;
                } else {
                    $ups_data->{$key} = $value;
                }
            }
        }

        _normalize_ups_data($ups_data);
    };
    if ($@) {
        debug(__LINE__, "Error parsing upsc output: $@");
    }

    debug(__LINE__, "Completed parsing upsc output");

    return $ups_data;
}

# ============================================================================
# UPS — data normalization
# ============================================================================

sub _normalize_ups_data {
    my ($ups_data) = @_;

    # Some devices report a placeholder (e.g. "OPEN") instead of a real date
    if (defined $ups_data->{'battery.mfr.date'} && $ups_data->{'battery.mfr.date'} !~ m{^\d{4}[/-]\d{1,2}[/-]\d{1,2}$}) {
        delete $ups_data->{'battery.mfr.date'};
    }

    # Derive real power draw for devices that don't report ups.realpower directly
    if (!defined $ups_data->{'ups.realpower'}) {
        if (defined $ups_data->{'ups.load'} && defined $ups_data->{'ups.realpower.nominal'}) {
            $ups_data->{'ups.realpower'} = int((($ups_data->{'ups.load'} / 100) * $ups_data->{'ups.realpower.nominal'}) + 0.5);
        } elsif (defined $ups_data->{'output.current'} && defined $ups_data->{'output.voltage'}) {
            $ups_data->{'ups.realpower'} = int(($ups_data->{'output.current'} * $ups_data->{'output.voltage'}) + 0.5);
        }
    }

    return;
}

1;
