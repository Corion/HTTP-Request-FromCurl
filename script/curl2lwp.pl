#!perl
use strict;
use warnings;

use HTTP::Request::FromCurl;

my $has_tidy;
BEGIN { eval { require Perl::Tidy; $has_tidy = 1; } }

my $request = HTTP::Request::FromCurl->new(
    argv => [ @ARGV ],
    read_files => 1,
) or exit 1; # Getopt::Long has already printed the error message

my $lwp = $request->as_snippet( type => 'LWP' );

if( $has_tidy and ! $no_tidy) {
    my $formatted;
    Perl::Tidy::perltidy(
        source      => \$lwp,
        destination => \$formatted,
        argv        => [ '--no-memoize' ],
    ) or $lwp = $formatted;
}

print $lwp;
