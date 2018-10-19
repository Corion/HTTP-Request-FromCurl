#!perl
use strict;
use warnings;

use HTTP::Request::FromUrl;
use Data::Dumper;

my $request = HTTP::Request::FromUrl->new(
    command_line => [ @ARGV ],
);

print Dumper $request;

my $template = do { local $/; <DATA> };

__DATA__
#!perl
use strict;
use warnings;

use HTTP::Request;
use LWP::UserAgent;

my $request = HTTP::Request->new(
    __ARGS__
);

$ua->request($request);