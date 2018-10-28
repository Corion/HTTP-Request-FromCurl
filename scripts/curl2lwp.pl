#!perl
use strict;
use warnings;

use HTTP::Request::FromCurl;

my $request = HTTP::Request::FromCurl->new(
    argv => [ @ARGV ],
);

print $request->as_snippet( type => 'LWP' );
