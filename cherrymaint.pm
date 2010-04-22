package cherrymaint;
use Dancer;
use HTML::Entities;

my $BLEADGITHOME = config->{gitroot};
my $STARTPOINT = config->{startpoint};
my $ENDPOINT = config->{endpoint};
my $TARGET = config->{target};
my $GIT = "/usr/bin/git";
$ENV{GIT_NOTES_REF} = "refs/notes/cherrymaint/$TARGET";

chdir $BLEADGITHOME or die "Can't chdir to $BLEADGITHOME: $!\n";

our %filecache;
sub read_blob_sha1 {
	my $sha1 = shift;
	return $filecache{$sha1} if exists $filecache{$sha1};
	$filecache{$sha1} = qx($GIT cat-file blob $sha1);
}

sub load_datafile {
    my $data = {};
    open my $fh, '-|', $GIT, qw(ls-tree -r), $ENV{GIT_NOTES_REF} or die $!;
    while (<$fh>) {
        my ($mode, $type, $sha1, $filename) = split / /;
	(my $commit = $filename) =~ s{/}{}g;
        $data->{$commit} = 0 + read_sha1($sha1);
    }
    close $fh;
    return $data;
}

sub set_commit_state {
    my $commit = shift;
    my $state = shift;
    system($GIT, qw(notes -m $state -f), $commit) == 0
	 or die "git notes failed; $!";
}

get '/' => sub {
    my @log = qx($GIT log --no-color --oneline $STARTPOINT..$ENDPOINT);
    my $data = load_datafile;
    my @commits;
    for my $log (@log) {
        chomp $log;
        my ($commit, $message) = split / /, $log, 2;
        $commit =~ /^[0-9a-f]+$/ or die;
        $message = encode_entities($message);
        push @commits, {
            sha1 => $commit,
            msg => $message,
            status => $data->{$commit} || 0,
        };
    }
    template 'index', { commits => \@commits };
};

get '/mark' => sub {
    my $commit = params->{commit};
    my $value = params->{value};
    $commit =~ /^[0-9a-f]+$/ or die;
    $value =~ /^[0-9]$/ or die;
    my $data = load_datafile;
    set_commit_state($commit, $value);
};

true;
