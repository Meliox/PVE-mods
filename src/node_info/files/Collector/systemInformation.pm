package PVE::PVEMod::Collector::SystemInformation;

use strict;
use warnings;
use Exporter 'import';

use PVE::PVEMod::Config qw(%config);
use PVE::PVEMod::Utils  qw(debug);

our @EXPORT_OK = qw(
    get_system_information_data
);

# ============================================================================
# System Information — one-time dmidecode call
# ============================================================================

sub get_system_information_data {
    unless ($config{system_info}{enabled}) {
        debug(__LINE__, "System information collection is disabled");
        return {};
    }

    my $raw_type = $config{system_info}{type};

    # Taint-safe: only allow type 1 (System) or 2 (Baseboard/Motherboard)
    my $type;
    if (defined $raw_type && $raw_type =~ /^([12])$/) {
        $type = $1;
    } else {
        debug(__LINE__, "Invalid system_info type '${\($raw_type // 'undef')}', defaulting to 1");
        $type = 1;
    }

    debug(__LINE__, "Collecting system information via dmidecode -t $type");

    return _get_system_info($type);
}

# ============================================================================
# Internal — run dmidecode and parse output
# ============================================================================

sub _get_system_info {
    my ($type) = @_;

    my $cache_file = "/var/lib/pve-mod/dmidecode-type${type}.txt";
    my $output;
    if (open(my $fh, '<', $cache_file)) {
        local $/;
        $output = <$fh>;
        close($fh);
    }

    unless (defined $output && length($output) > 0) {
        debug(__LINE__, "No cached DMI data at $cache_file — re-run pve-mod-configure as root to refresh");
        return {};
    }

    my %fields;
    my @field_order;

    for my $line (split /\n/, $output) {
        if ($line =~ /^\s+(Manufacturer|Product Name|Serial Number):\s*(.+)$/) {
            my ($key, $value) = ($1, $2);
            $value =~ s/^\s+|\s+$//g;

            my $field_key = lc($key);
            $field_key =~ s/ /_/g;

            unless (exists $fields{$field_key}) {
                push @field_order, $field_key;
                $fields{$field_key} = $value;
            }
        }
    }

    unless (%fields) {
        debug(__LINE__, "No recognised fields found in dmidecode output");
        return {};
    }

    # Build display string: "Manufacturer: X | Product Name: Y | Serial Number: Z"
    my %pretty_key = (
        manufacturer  => 'Manufacturer',
        product_name  => 'Product Name',
        serial_number => 'Serial Number',
    );

    my @parts;
    for my $key (@field_order) {
        my $label = $pretty_key{$key} // $key;
        push @parts, "$label: $fields{$key}";
    }
    $fields{display_string} = join(' | ', @parts);

    debug(__LINE__, "System information: $fields{display_string}");

    return \%fields;
}

1;
