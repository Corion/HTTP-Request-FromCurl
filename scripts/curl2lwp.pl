#!perl
use strict;
use warnings;

use HTTP::Request::FromCurl;

my $request = HTTP::Request::FromCurl->new(
    argv => [ @ARGV ],
);

if( $request ) {
    print $request->as_snippet( type => 'LWP' );
} else {
    # Getopt::Long has already printed the error message
    exit 1;
};
