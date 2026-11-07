#!/usr/bin/perl
# build/test/storage-health.t
#
# Fixture-based tests for the node_info storage health collector: the
# 'zpool status' and 'smartctl -j' parsers and the evaluation that turns them
# into the summary shown on the node Summary. Run through test-storage-health.sh,
# which puts the module sources on @INC.

use strict;
use warnings;
use Test::More;
use JSON;
use File::Temp qw(tempdir);

use PVE::PVEMods::Config qw(%config);
use PVE::PVEMods::Collector::StorageHealth qw(
    parse_zpool_status parse_smartctl_json evaluate_storage_health
);

my $fixtures = $ENV{STORAGE_HEALTH_FIXTURES} or die "STORAGE_HEALTH_FIXTURES not set\n";

sub slurp {
    my ($name) = @_;
    open(my $fh, '<', "$fixtures/$name") or die "Cannot read $fixtures/$name: $!";
    local $/;
    return scalar <$fh>;
}

sub pools   { return parse_zpool_status(slurp("zpool-$_[0].txt")) }
sub drive   { return parse_smartctl_json(slurp("smart-$_[0].json")) }

sub evaluate {
    my (%args) = @_;
    return evaluate_storage_health({ smart_enabled => 0, now => 1_000_000, %args });
}

sub texts { return [ map { $_->{text} } @{ $_[0]{issues} } ] }

# --- zpool status ----------------------------------------------------------

{
    my $pools = pools('online');
    is(scalar(@$pools), 2, 'online: two pools parsed');
    is($pools->[0]{name}, 'tank', 'online: pool name');
    is(scalar(grep { $_->{leaf} } @{ $pools->[0]{devices} }), 3, 'online: three leaf drives, vdev not a leaf');
    my $result = evaluate(pools => $pools);
    is($result->{status}, 'ok', 'online: status ok');
    is($result->{summary}, 'OK', 'online: summary OK');
    is($result->{zfs}{pools}, 2, 'online: pool count reported');
}

{
    my $pools = pools('degraded');
    is($pools->[0]{state}, 'DEGRADED', 'degraded: pool state');
    my ($removed) = grep { $_->{state} eq 'REMOVED' } @{ $pools->[0]{devices} };
    ok($removed && $removed->{leaf}, 'degraded: removed drive found as leaf');
    my $result = evaluate(pools => $pools);
    is($result->{status}, 'critical', 'degraded: critical');
    is($result->{summary}, 'tank DEGRADED: drive removed', 'degraded: summary names pool and cause');
    is(scalar(@{ $result->{issues} }), 1, 'degraded: finished scrub is not an issue');
}

{
    my $result = evaluate(pools => pools('resilver'));
    is($result->{status}, 'warning', 'resilver: warning');
    is($result->{summary}, 'tank resilvering: 37%, 12 minutes remaining', 'resilver: progress and ETA');
}

{
    my $result = evaluate(pools => pools('scrub'));
    is($result->{status}, 'info', 'scrub: info');
    is($result->{summary}, 'tank scrubbing: 14%, 8 hours remaining', 'scrub: progress and ETA');
}

{
    my $result = evaluate(pools => pools('read-errors'));
    is($result->{status}, 'warning', 'read errors: warning on an ONLINE pool');
    is($result->{summary}, 'tank: read/write/checksum errors on sda1', 'read errors: names the drive');
    is(scalar(@{ $result->{issues} }), 1, 'read errors: healthy cache device not reported');
}

{
    my $result = evaluate(pools => pools('data-errors'));
    is($result->{status}, 'critical', 'data errors: critical');
    is($result->{summary}, 'tank: data errors', 'data errors: summary');
}

{
    my $text = <<'ZPOOL';
  pool: tank
 state: DEGRADED
config:

	NAME           STATE     READ WRITE CKSUM
	tank           DEGRADED     0     0     0
	  mirror-0     DEGRADED     0     0     0
	    /dev/sda1  UNAVAIL      0     0     0
	    /dev/sdb1  FAULTED      0     0     0  too many errors

errors: No known data errors
ZPOOL
    my $result = evaluate(pools => parse_zpool_status($text));
    is($result->{summary}, 'tank DEGRADED: drive unavailable, drive faulted', 'mixed member states listed');
}

is_deeply(parse_zpool_status("no pools available\n"), [], 'no pools available parses to an empty list');
is_deeply(parse_zpool_status(undef), [], 'undef parses to an empty list');

# --- smartctl --------------------------------------------------------------

{
    my $d = drive('ata-ssd-ok');
    is($d->{name}, 'sda', 'ata ssd: name');
    is($d->{model}, 'Samsung SSD 870 EVO 1TB', 'ata ssd: model');
    is($d->{passed}, 1, 'ata ssd: overall health passed');
    is($d->{life_remaining}, 95, 'ata ssd: wear leveling count is remaining life');
    is_deeply($d->{failing_attrs}, [], 'ata ssd: nothing failing');
    is(evaluate(devices => [$d])->{status}, 'ok', 'ata ssd: healthy');
}

{
    my $d = drive('ata-ssd-low-life');
    is($d->{life_remaining}, 15, 'low life: SSD_Life_Left read');
    my $result = evaluate(devices => [$d], life_warning => 20, life_critical => 10);
    is($result->{status}, 'warning', 'low life: warning below the warning threshold');
    is($result->{summary}, 'sdd life remaining: 15%', 'low life: summary');
    is(evaluate(devices => [$d], life_warning => 30, life_critical => 20)->{status}, 'critical',
        'low life: thresholds are configurable');
    is(evaluate(devices => [$d], life_warning => 10, life_critical => 5)->{status}, 'ok',
        'low life: above both thresholds is fine');
}

{
    my $d = drive('ata-hdd-failing');
    is($d->{passed}, 0, 'failing hdd: overall health failed');
    is_deeply($d->{failing_attrs}, ['Reallocated_Sector_Ct'], 'failing hdd: FAILING_NOW attribute');
    ok(!defined $d->{life_remaining}, 'failing hdd: rotational drive has no SSD life');
    my $result = evaluate(devices => [$d]);
    is($result->{status}, 'critical', 'failing hdd: critical');
    is_deeply(texts($result),
        ['sdc SMART failure', 'sdc SMART attribute failing: Reallocated_Sector_Ct'],
        'failing hdd: failure listed before the attribute');
}

{
    my $d = drive('ata-hdd-historical');
    is_deeply($d->{failing_attrs}, [], 'historical: In_the_past is not a current failure');
    is(evaluate(devices => [$d])->{status}, 'ok', 'historical: healthy');
}

{
    my $d = drive('ata-standby');
    is($d->{state}, 'sleeping', 'standby: detected from the smartctl message');
    is($d->{name}, 'sdf', 'standby: name');
    ok(!defined $d->{passed}, 'standby: no health claimed');
    is(evaluate(devices => [$d])->{status}, 'ok', 'standby: a skipped check is not a failure');
}

{
    my $d = drive('nvme-worn');
    is($d->{life_remaining}, 7, 'nvme: life from percentage used');
    is($d->{critical_warning}, 0, 'nvme: no critical warning');
    my $result = evaluate(devices => [$d]);
    is($result->{status}, 'critical', 'nvme worn: critical at 7% remaining');
    is($result->{summary}, 'nvme6 life remaining: 7%', 'nvme worn: summary');
}

{
    my $d = drive('nvme-critical');
    is($d->{critical_warning}, 5, 'nvme critical: flags read');
    my $result = evaluate(devices => [$d]);
    is($result->{status}, 'critical', 'nvme critical: critical');
    ok((grep { $_ eq 'nvme1 critical warning: available spare below threshold, reliability degraded' }
        @{ texts($result) }), 'nvme critical: flags decoded');
}

{
    my $d = parse_smartctl_json(
        '{"smartctl":{"exit_status":0},"device":{"name":"/dev/nvme2","type":"nvme","protocol":"NVMe"},'
        . '"smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":2,"percentage_used":3}}');
    is(evaluate(devices => [$d])->{status}, 'warning', 'nvme temperature flag alone is a warning');
}

{
    my $d = drive('scsi-ok');
    is($d->{type}, 'scsi', 'scsi: type');
    is($d->{passed}, 1, 'scsi: health passed');
    is(evaluate(devices => [$d])->{status}, 'ok', 'scsi: healthy');
    is(drive('unreadable')->{state}, 'unreadable', 'unreadable device is flagged, not failed');
    is(evaluate(devices => [drive('unreadable')])->{status}, 'ok', 'unreadable device is ignored');
}

ok(!defined parse_smartctl_json('not json'), 'invalid JSON is rejected');
ok(!defined parse_smartctl_json('{"foo":1}'), 'JSON without smartctl block is rejected');

# --- combined evaluation ---------------------------------------------------

{
    my $result = evaluate(
        pools   => pools('degraded'),
        devices => [ drive('nvme-worn'), drive('ata-ssd-ok') ],
    );
    is($result->{summary}, 'tank DEGRADED: drive removed', 'highest priority issue is shown first');
    is(scalar(@{ $result->{issues} }), 2, 'all issues are kept for the tooltip');
    is($result->{smart}{devices}, 2, 'SMART device count');
}

{
    my $result = evaluate(
        devices => [ drive('ata-ssd-low-life'), drive('ata-hdd-failing') ],
    );
    is($result->{issues}[0]{severity}, 'critical', 'critical issues sort before warnings');
}

{
    my $sleeping = drive('ata-standby');
    $sleeping->{sleeping} = 1;
    my $pending = { name => 'sdi', dev => '/dev/sdi', state => 'pending', sleeping => 1, checked => 0 };
    my $result = evaluate(devices => [ drive('ata-ssd-ok'), $sleeping, $pending ]);
    is($result->{status}, 'ok', 'sleeping and pending drives do not raise issues');
    is($result->{smart}{sleeping}, 2, 'sleeping drives counted');
    is($result->{smart}{unchecked}, 1, 'drives never checked counted');
}

{
    my $stale = drive('ata-ssd-ok');
    $stale->{checked} = 1_000_000 - 20_000;
    my $result = evaluate(devices => [$stale], smart_interval => 1800);
    is($result->{summary}, 'SMART data is out of date', 'stale SMART results are called out');
    is($result->{status}, 'info', 'stale SMART results are informational');
}

{
    my $result = evaluate(pools => pools('online'), smart_enabled => 1);
    is($result->{summary}, 'SMART data unavailable', 'missing SMART results are informational');
    is($result->{status}, 'info', 'missing SMART results do not raise an alarm');
    is(evaluate(pools => pools('online'), smart_enabled => 0)->{status}, 'ok', 'SMART off: ZFS alone is enough');
}

{
    my $result = evaluate();
    is($result->{status}, 'unknown', 'no data at all is unknown');
}

# --- collector in debug mode ----------------------------------------------

{
    my $dir = tempdir(CLEANUP => 1);
    open(my $zfh, '>', "$dir/zpool.txt") or die $!;
    print $zfh slurp('zpool-degraded.txt');
    close($zfh);

    my @decoded = map { decode_json(slurp("smart-$_.json")) } qw(ata-ssd-ok nvme-worn ata-standby);
    open(my $sfh, '>', "$dir/smartctl.json") or die $!;
    print $sfh encode_json(\@decoded);
    close($sfh);

    $config{debug}{storage_health_mode} = 1;
    $config{debug}{zpool_output_file}   = "$dir/zpool.txt";
    $config{debug}{smartctl_output_file} = "$dir/smartctl.json";
    $config{storage_health}{smart_enabled} = 1;

    my $summary = PVE::PVEMods::Collector::StorageHealth::_collect_storage_health();
    is($summary->{status}, 'critical', 'debug collector: critical');
    is($summary->{summary}, 'tank DEGRADED: drive removed', 'debug collector: summary');
    is($summary->{smart}{devices}, 3, 'debug collector: sample drives read');
    ok(ref($summary->{zfs}{available}) eq 'SCALAR' || JSON::is_bool($summary->{zfs}{available}), 'debug collector: JSON booleans');
    my $encoded = eval { encode_json($summary) };
    ok(defined $encoded && $encoded =~ /"status":"critical"/, 'debug collector: summary encodes to JSON');
    like($encoded, qr/"devices":3\b/, 'debug collector: counts are encoded as numbers');
}

done_testing();
