#!perl
#!perl
use strict;
use Test::More;
use HTTP::Request::FromCurl;

use lib 't';
use TestCurlIdentity 'run_curl_tests', '$server';

my @tests = (
    { cmd => [ '--verbose', '-s', '$url', '$url?foo=bar', ] },
    { cmd => [ '--verbose', '-s', '$url?foo={bar,baz}', ] },
    { cmd => [ '--verbose', '-s', '-g', '$url', '$url?foo={bar,baz}', ] },
    { cmd => [ '--verbose', '-s', '--globoff', '$url', '$url?foo={bar,baz}', ] },
);

if( $server->url =~ m!\[! ) {
    plan( skip_all => "Curl URL-globbing and IPv6 do not play together" );
} else {
    run_curl_tests( @tests );
};
