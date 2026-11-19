package PVE::PVEMods::Collector::SysfsSensors;

use strict;
use warnings;
use Cwd qw(abs_path);
use Exporter 'import';
use Fcntl qw(O_RDONLY O_NOFOLLOW);
use File::Basename qw(basename dirname);
use File::Glob qw(bsd_glob GLOB_NOSORT);
use JSON::PP qw(decode_json);
use POSIX qw(isfinite);
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

our @EXPORT_OK = qw(merge_sysfs_temperatures);
our $SYSFS_ROOT = '/sys';
our $SOURCES_FILE = '/usr/share/pve-mods/sysfs-temperature-sources.json';
our $OVERRIDES_FILE = '/etc/pve-mods/sysfs-temperature-sources.json';

sub _now { return clock_gettime(CLOCK_MONOTONIC); }

sub _warn_once {
    my ($cache, $key, $message) = @_;
    return if ($cache->{errors}{$key} // '') eq $message;
    $cache->{errors}{$key} = $message;
    warn "pve-mods sysfs sensors: $message\n";
}

sub _number {
    my ($value) = @_;
    return defined($value) && !ref($value) && looks_like_number($value) && isfinite(0 + $value);
}

sub _load_sources {
    my ($cache) = @_;
    my %sources;
    for my $file ($SOURCES_FILE, $OVERRIDES_FILE) {
        next if $file eq $OVERRIDES_FILE && !-e $file;
        my $fh;
        if (!open($fh, '<', $file)) {
            _warn_once($cache, "config:$file", "cannot read $file: $!");
            next;
        }
        my $text = do { local $/; <$fh> };
        close $fh;
        my $data = eval { decode_json($text // '') };
        if ($@ || ref($data) ne 'HASH' || ref($data->{sources}) ne 'ARRAY') {
            _warn_once($cache, "config:$file", "invalid source list in $file (expected a sources array)");
            next;
        }
        delete $cache->{errors}{"config:$file"};
        my %seen;
        for my $entry (@{$data->{sources}}) {
            if (ref($entry) ne 'HASH' || !defined($entry->{id}) || ref($entry->{id})
                || $entry->{id} !~ /\A[a-z][a-z0-9_-]*\z/) {
                _warn_once($cache, "entry:$file", "invalid source id in $file");
                next;
            }
            my $id = $entry->{id};
            my $key = "source:$file:$id";
            my %source = (%{$sources{$id} // {}}, %$entry);
            my $enabled = exists($source{enabled}) ? $source{enabled} : 1;
            if ($seen{$id}++
                || grep({ !/\A(?:id|label|path|temp_scale|enabled|max|crit)\z/ } keys %source)
                || !defined($enabled)
                || !(JSON::PP::is_bool($enabled) || (!ref($enabled) && $enabled =~ /\A[01]\z/))) {
                _warn_once($cache, $key, "invalid or duplicate source '$id' in $file");
                next;
            }
            if ($enabled) {
                my $path = $source{path};
                my $temp_scale = exists($source{temp_scale}) ? $source{temp_scale} : 1;
                if (!defined($source{label}) || ref($source{label}) || !length($source{label})
                    || !defined($path) || ref($path) || $path !~ m{\A/sys/[a-zA-Z0-9_./:*-]+\z}
                    || $path =~ m{(?:^|/)\.\.?(?:/|$)}
                    || !_number($temp_scale) || $temp_scale <= 0
                    || grep({ exists($source{$_}) && !_number($source{$_}) } qw(max crit))
                    || (defined($source{max}) && defined($source{crit}) && $source{max} > $source{crit})) {
                    _warn_once($cache, $key, "invalid temperature definition for '$id' in $file");
                    next;
                }
                $source{temp_scale} = 0 + $temp_scale;
            }
            delete $cache->{errors}{$key};
            $sources{$id} = \%source;
        }
    }
    return [map { $sources{$_} } sort keys %sources];
}

sub _signature {
    my ($file) = @_;
    my @stat = Time::HiRes::stat($file);
    return join(':', $file, @stat ? @stat[1, 7, 9, 10] : 'missing');
}

sub _discover {
    my ($cache) = @_;
    my $root = abs_path($SYSFS_ROOT);
    return [] unless defined $root;
    my @devices;
    for my $source (@{_load_sources($cache)}) {
        next if exists($source->{enabled}) && !$source->{enabled};
        my $pattern = $source->{path};
        $pattern =~ s{\A/sys}{$root};
        my %seen;
        for my $path (sort(bsd_glob($pattern, GLOB_NOSORT))) {
            my $resolved = abs_path($path);
            if (!defined($resolved) || index($resolved, "$root/") != 0 || !-f $resolved) {
                _warn_once($cache, "path:$path", "ignoring invalid sysfs temperature path $path");
                next;
            }
            next if $seen{$resolved}++;
            my $relative = substr($resolved, length($root) + 1);
            my $device_path = abs_path(dirname($path) . '/device');
            $device_path = $resolved if !defined($device_path) || index($device_path, "$root/") != 0;
            my @pci = $device_path =~ m{(?:^|/)([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])(?=/|$)}g;
            my $identity = @pci ? $pci[-1] . ', ' . basename(dirname($path)) : basename(dirname($path));
            # Encode separators instead of replacing them, so distinct paths cannot collide.
            $relative =~ s/([^a-zA-Z0-9_.:-])/sprintf('%%%02X', ord($1))/ge;
            push @devices, {
                %$source,
                key => "sysfs-$source->{id}-$relative",
                path => $resolved,
                label => "$source->{label} ($identity)",
                (@pci ? (pci_address => $pci[-1]) : ()),
            };
        }
    }
    return \@devices;
}

sub merge_sysfs_temperatures {
    my ($sensors, $cache) = @_;
    my $now = _now();
    my $signature = join('|', $SYSFS_ROOT, _signature($SOURCES_FILE), _signature($OVERRIDES_FILE));
    if (!defined($cache->{next_discovery}) || $now >= $cache->{next_discovery}
        || ($cache->{signature} // '') ne $signature) {
        $cache->{devices} = _discover($cache);
        $cache->{signature} = $signature;
        $cache->{next_discovery} = $now + 60;
    }
    for my $device (@{$cache->{devices}}) {
        my $path = $device->{path};
        my ($fh, $raw);
        if (!sysopen($fh, $path, O_RDONLY | O_NOFOLLOW)) {
            _warn_once($cache, "read:$path", "cannot read $path: $!");
            next;
        }
        my $length = sysread($fh, $raw, 128);
        close $fh;
        if (!defined($length) || $length == 128) {
            _warn_once($cache, "read:$path", "cannot read a numeric temperature from $path");
            next;
        }
        $raw =~ s/^\s+|\s+$//g;
        if ($raw !~ /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/
            || !_number($raw) || !isfinite((0 + $raw) * $device->{temp_scale})) {
            _warn_once($cache, "read:$path", "invalid numeric temperature in $path");
            next;
        }
        delete $cache->{errors}{"read:$path"};
        my $key = $device->{key};
        if (exists $sensors->{$key}) {
            _warn_once($cache, "collision:$key", "not overwriting existing sensor '$key'");
            next;
        }
        my $feature = {
            input => { value => (0 + $raw) * $device->{temp_scale}, quantity => 'temperature', unit => 'C' },
        };
        $feature->{$_} = { value => 0 + $device->{$_}, quantity => 'temperature', unit => 'C' }
            for grep { exists $device->{$_} } qw(max crit);
        $sensors->{$key} = {
            Adapter => 'sysfs',
            source => 'sysfs',
            label => $device->{label},
            (exists($device->{pci_address}) ? (pci_address => $device->{pci_address}) : ()),
            temp1 => $feature,
        };
    }
    return $sensors;
}

1;
