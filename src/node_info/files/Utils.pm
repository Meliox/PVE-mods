package PVE::PVEMod::Utils;

use strict;
use warnings;
use Exporter 'import';

use JSON;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);

use PVE::PVEMod::Config qw($DEBUG_ENABLED $VERSION $pve_mod_working_dir %config);

my $debug_log_fh;

our @EXPORT_OK = qw(
    debug
    read_sysfs
    is_process_alive
    read_lock_pid
    acquire_exclusive_lock
    ensure_pve_mod_directory_exists
    check_executable
    startup_message
    setup_collector_signals
    safe_write_json
    safe_read_json
    parse_csv_line
);

# ============================================================================
# Debug
# ============================================================================

# debug function showing line number and call chain
# Usage: debug(__LINE__, "message")
sub debug {
    return unless $DEBUG_ENABLED;

    my ($line, $message) = @_;

    my @caller1 = caller(1);  # who called debug()
    my @caller2 = caller(2);  # parent of caller

    my $sub1 = $caller1[3] || 'main';
    my $sub2 = $caller2[3];

    $sub1 =~ s/.*:://;

    my $output;
    if (defined $sub2) {
        $sub2 =~ s/.*:://;
        $output = "[$sub2 -> $sub1:$line] $message\n";
    } else {
        $output = "[$sub1:$line] $message\n";
    }

    warn $output;

    if ($config{debug}{log_enabled} && !defined $debug_log_fh) {
        if (open(my $fh, '>>', $config{debug}{log_file})) {
            $fh->autoflush(1);
            $debug_log_fh = $fh;
        } else {
            warn "[debug] Failed to open log file $config{debug}{log_file}: $!\n";
        }
    }
    print $debug_log_fh $output if defined $debug_log_fh;
}

# ============================================================================
# File / Process helpers
# ============================================================================

sub read_sysfs {
    my ($path) = @_;

    return "unknown" unless defined $path && -f $path;

    if (open my $fh, '<', $path) {
        my $value = <$fh>;
        close $fh;

        if (defined $value) {
            chomp $value;
            $value =~ s/^\s+|\s+$//g;
            return $value ne '' ? $value : "unknown";
        }
    }

    return "unknown";
}

sub is_process_alive {
    my ($pid) = @_;
    return -d "/proc/$pid";
}

sub read_lock_pid {
    my ($lock_path) = @_;

    return undef unless open(my $fh, '<', $lock_path);

    my $pid = <$fh>;
    close($fh);
    chomp $pid if defined $pid;

    return $pid;
}

sub acquire_exclusive_lock {
    my ($lock_path, $purpose) = @_;
    $purpose //= 'lock';

    my $fh;

    if (sysopen($fh, $lock_path, O_CREAT|O_EXCL|O_WRONLY, 0644)) {
        debug(__LINE__, "Acquired $purpose on first try");
        return $fh;
    }

    debug(__LINE__, ucfirst($purpose) . " exists, checking if stale");

    my $lock_pid = read_lock_pid($lock_path);

    if (!defined $lock_pid) {
        debug(__LINE__, "Could not read $purpose file: $!");
        return undef;
    }

    if ($lock_pid eq '' || $lock_pid !~ /^\d+$/) {
        debug(__LINE__, "Invalid PID in $purpose: '" . ($lock_pid // 'undefined') . "', removing");
        unlink($lock_path);
    } elsif (is_process_alive($lock_pid)) {
        debug(__LINE__, ucfirst($purpose) . " holder PID $lock_pid is still alive");
        return undef;
    } else {
        debug(__LINE__, ucfirst($purpose) . " holder PID $lock_pid is dead, removing stale lock");
        unlink($lock_path);
    }

    unless (sysopen($fh, $lock_path, O_CREAT|O_EXCL|O_WRONLY, 0644)) {
        debug(__LINE__, "Failed to acquire $purpose on retry: $!");
        return undef;
    }

    debug(__LINE__, "Acquired $purpose after removing stale lock");
    return $fh;
}

sub ensure_pve_mod_directory_exists {
    unless (-d $pve_mod_working_dir) {
        debug(__LINE__, "Creating directory $pve_mod_working_dir");
        unless (mkdir($pve_mod_working_dir, 0755)) {
            debug(__LINE__, "Failed to create $pve_mod_working_dir: $!. PVE Mod cannot start.");
            die "Failed to create $pve_mod_working_dir: $!";
        }
        debug(__LINE__, "Directory $pve_mod_working_dir created");
    } else {
        debug(__LINE__, "Directory $pve_mod_working_dir already exists");
    }
}

# Returns 1 if executable exists, or debug mode is active with a debug file present.
# Returns 0 otherwise.
sub check_executable {
    my ($exec_path, $type, $debug_mode_enabled, $debug_file) = @_;

    if (defined $debug_mode_enabled && $debug_mode_enabled) {
        if (defined $debug_file && -f $debug_file) {
            debug(__LINE__, "Debug mode enabled for $type, using debug file: $debug_file");
            return 1;
        } elsif (defined $debug_file) {
            debug(__LINE__, "Debug mode enabled for $type but debug file missing: $debug_file");
            return 0;
        } else {
            debug(__LINE__, "Debug mode enabled for $type, skipping executable check for $exec_path");
            return 1;
        }
    }

    unless (-x $exec_path) {
        debug(__LINE__, "$type executable not found or not executable: $exec_path");
        return 0;
    }

    debug(__LINE__, "$type executable found: $exec_path");
    return 1;
}

sub startup_message {
    debug(__LINE__, "PVE Mod is being started. Version $VERSION");
}

# Setup common TERM/INT signal handlers for collector processes.
# $shutdown_ref is a scalar ref that will be set to 1 on signal.
sub setup_collector_signals {
    my ($name, $shutdown_ref, $extra_cleanup) = @_;

    $SIG{TERM} = sub {
        debug(__LINE__, "Collector $name received SIGTERM");
        $$shutdown_ref = 1;
        $extra_cleanup->() if $extra_cleanup;
    };
    $SIG{INT} = sub {
        debug(__LINE__, "Collector $name received SIGINT");
        $$shutdown_ref = 1;
        $extra_cleanup->() if $extra_cleanup;
    };
}

# ============================================================================
# JSON helpers
# ============================================================================

sub safe_write_json {
    my ($filepath, $data, $pretty) = @_;
    $pretty //= 1;

    # Untaint filepath for taint-mode environments (pveproxy runs with -T)
    ($filepath) = ($filepath =~ /^([a-zA-Z0-9_\/\-\.]+)$/)
        or do { debug(__LINE__, "Unsafe filepath rejected: $filepath"); return 0; };

    eval {
        open my $fh, '>', $filepath or die "Failed to open $filepath: $!";
        my $json = $pretty ? JSON->new->pretty->encode($data) : encode_json($data);
        print $fh $json;
        close $fh;
        debug(__LINE__, "Wrote JSON to $filepath");
    };
    if ($@) {
        debug(__LINE__, "Error writing to $filepath: $@");
        return 0;
    }
    return 1;
}

sub safe_read_json {
    my ($filepath, $as_string) = @_;

    # Untaint filepath
    ($filepath) = ($filepath =~ /^([a-zA-Z0-9_\/\-\.]+)$/)
        or return;

    return unless -f $filepath;

    my $result;
    eval {
        open my $fh, '<', $filepath or die "Failed to open $filepath: $!";
        local $/;
        my $json = <$fh>;
        close $fh;

        if ($as_string) {
            $result = $json;
        } else {
            $result = decode_json($json);
        }
        debug(__LINE__, "Read JSON from $filepath");
    };
    if ($@) {
        debug(__LINE__, "Error reading $filepath: $@");
        return;
    }
    return $result;
}

# ============================================================================
# CSV helper
# ============================================================================

sub parse_csv_line {
    my ($line, $expected_fields) = @_;

    return unless $line;
    $line =~ s/^\s+|\s+$//g;

    my @values = map { s/^\s+|\s+$//gr } split(/,/, $line);

    return unless !$expected_fields || @values >= $expected_fields;
    return @values;
}

1;
