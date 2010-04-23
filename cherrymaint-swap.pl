#!/usr/bin/perl

use cherrymaint;
use Dancer;

my $dir = config->{gitroot};
chdir($dir);

# set up the config if not already done
my $remote = config->{remote} || "origin";
my $GIT = $cherrymaint::GIT;
my $target = config->{target};

my $notes_ref = $cherrymaint::NOTES_REF;
my $tracking_ref = "refs/remotes/$remote/notes/cherrymaint/$target";

my $fetch_line = "$notes_ref:$tracking_ref";

# fetch the latest
system($GIT, "fetch", $remote, "+$fetch_line");

# check for changes on either side
my $remote_ref = qx($GIT rev-parse --verify $tracking_ref);
my @remote_changes;
my @local_changes;
my $plus = "";
if ( !$remote_ref ) {
	print "No-one has pushed to $notes_ref remotely yet\n";
	$plus = "+";
	@local_changes = qx($GIT rev-list $notes_ref);
}
else {
	my @fetch_lines=qx($GIT config --get-all remote.$remote.fetch);
	unless ( grep { m{^\+?\Q$fetch_line\E$} } @fetch_lines ) {
		system($GIT, "config", "--add", "remote.$remote.fetch",
		       "+$fetch_line");
	}
	@remote_changes = qx($GIT rev-list $notes_ref..$tracking_ref);
	@local_changes = qx($GIT rev-list $tracking_ref..$notes_ref);
}

# ...and act accordingly
if ( @remote_changes ) {
	if ( !@local_changes ) {
		# local fast-forward OK
		system($GIT, "update-ref", $notes_ref => $tracking_ref) == 0
			or die
	}
	else {
		# both sides have changes, merge!
		do_merge($notes_ref, $tracking_ref);
	}
}

# share our (possibly merged) changes
if ( @local_changes ) {
	system($GIT, "push", $remote, "$plus$notes_ref") == 0
		or die;
}

exit(0);

sub _display {
	my $sha1 = shift;
	if ( defined $sha1 ) {
		my $value = cherrymaint::read_blob_sha1($sha1);
		$value = 0+$value;
		my $max = @cherrymaint::states;
		die "bad value '$value'"
			if $value > $max or $value < 0;
		return $cherrymaint::states[$value];
	}
	else {
		return "(unset)";
	}
}

sub do_merge {
	my $notes_ref = shift;
	my $tracking_ref = shift;

	# what is the merge base?
	chomp(my $merge_base = qx($GIT merge-base $notes_ref $tracking_ref));

	# try a trivial in-index merge using a temporary index
	local($ENV{GIT_INDEX_FILE}) = ( -d ".git" ? ".git/" : "" )
		. "/cherrymaint.idx";
	unlink($ENV{GIT_INDEX_FILE});
	system($GIT, "read-tree", "-m",
	       ($merge_base ? ("$merge_base^{tree}") : ()),
	       "$notes_ref^{tree}", "$tracking_ref^{tree}");

	# check for 'unmerged' entries, ie entries which didn't change
	# the same way or conflicted
	my @conflicts = qx($GIT ls-files --cached -u);

	if ( @conflicts ) {
		my %stages;
		my %who;

		# get the states for merge resolution
		for ( @conflicts ) {
			my ($mode, $sha1, $stage, $filename) = split " ";
			$stages{$filename}[$stage] = $sha1;
		}

		# see who changed it differently
		for my $filename ( keys %stages ) {
			my ($commit, $who) =
				qx($GIT rev-list --pretty=format:%aN -1 $merge_base..$tracking_ref -- "$filename");
			chomp($who) if defined $who;
			$who{$filename} = $who;
		}

		# now display them all one by one and let the user
		# choose the resolution
		for my $filename ( keys %stages ) {
			(my $commitid = $filename) =~ s{/}{}g;
			print "For this commit:\n";
			system($GIT, qw(log -1), $commitid);
			my $orig = $stages{$filename}[1];
			my $local = $stages{$filename}[2];
			my $remote = $stages{$filename}[3];

			if ( $merge_base ) {
				print "Your side changed from "._display($orig)
					." to "._display($local)."\n";
			}
			else {
				print "Your side has "._display($local)."\n";
			}
			if ( $who{$filename} ) {
				print "$who{$filename} last set"
					." to "._display($remote)."\n";
			}
			else {
				print "unchanged from "._display($remote)." remotely\n";
			}

			my $answer = "kittens";
			while ( $answer !~ /^[lr]$/i ) {
				print "Accept [L]ocal or [R]emote? ";
				$answer = <STDIN>;
				die if !defined $answer;
				chomp($answer);
			}
			my $winner;
			if ( $answer =~ /l/i ) {
				$winner = $local;
			}
			else {
				$winner = $remote;
			}
			if ( defined $winner ) {
				system($GIT, "update-index", "--add",
				       "--cacheinfo", "100644",
				       $filename, $winner);
				print "Setting to "._display($winner)."\n";
			}
			else {
				system($GIT, qw(rm --cached),
				       $filename);
				print "Clearing record\n";
			}
		}
	}

	# all done - commit!
	my $tree = qx($GIT write-tree);
	die if $?;
	chomp($tree);
	unlink($ENV{GIT_INDEX_FILE});

	my $msg = "merged using cherrymaint-swap";
	my $commit = qx(echo $msg | $GIT commit-tree $tree -p $notes_ref -p $tracking_ref);
	die if $?;
	chomp($commit);
	system($GIT, "update-ref", "-m", $msg, $notes_ref, $commit);
	die if $?;
}
