#!perl
use strict;
use warnings;

use HTTP::Request::FromCurl;
use LWP::UserAgent;
use Getopt::Long ':config','pass_through';

# parse output options from @ARGV
GetOptions(
    'output|o=s' => \my $outfilename,
);

my @output_options;
if( $outfilename ) {
    push @output_options, $outfilename;
};

# now execute all requests
my @requests = HTTP::Request::FromCurl->new(
    argv => \@ARGV,
);

my $ua = LWP::UserAgent->new();

for my $request (@requests) {
print 
    $ua->request( $request, @output_options )->code;
};
