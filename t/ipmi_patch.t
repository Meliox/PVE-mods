use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;

my $root = tempdir(CLEANUP => 1);
my $nodes = "$root/usr/share/perl5/PVE/API2/Nodes.pm";
make_path("$root/usr/share/perl5/PVE/API2");
my $original = ("\n" x 535) . <<'NODES';

        $res->{pveversion} = PVE::pvecfg::package() . "/" . PVE::pvecfg::version_text();

        my $dinfo = df('/', 1); # output is bytes

        $res->{rootfs} = {
NODES
open my $out, '>', $nodes or die $!;
print {$out} $original;
close $out;

sub run_patch {
    my ($name, @flags) = @_;
    my $patch = "$FindBin::Bin/../src/modules/node_info/patches/$name";
    open my $input, '<', $patch or die $!;
    open my $command, '|-', 'patch', '-p1', '-F0', '-f', '-s', '-d', $root, @flags
        or die $!;
    print {$command} $_ while <$input>;
    close $input;
    return close $command;
}

ok(run_patch('01-nodes-pm-sensors.patch', '--dry-run'), 'existing patch preflights on clean Nodes.pm');
ok(run_patch('04-nodes-pm-ipmi.patch', '--dry-run'), 'IPMI patch independently preflights on clean Nodes.pm');
ok(run_patch('01-nodes-pm-sensors.patch'), 'existing patch applies');
ok(run_patch('04-nodes-pm-ipmi.patch'), 'IPMI patch applies after existing patch');
open my $input, '<', $nodes or die $!;
my $installed = do { local $/; <$input> };
close $input;
like($installed, qr/PveMod_ipmiInfo/, 'node status includes IPMI response');
ok(run_patch('04-nodes-pm-ipmi.patch', '-R'), 'IPMI patch reverts');
ok(run_patch('01-nodes-pm-sensors.patch', '-R'), 'existing patch reverts');
open $input, '<', $nodes or die $!;
my $reverted = do { local $/; <$input> };
close $input;
is($reverted, $original, 'original Nodes.pm restored');

done_testing();
