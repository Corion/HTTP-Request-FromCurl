#!perl
use strict;
use HTTP::Request::FromCurl;

use lib 't';
use TestCurlIdentity 'run_curl_tests';

my @tests = (
    { cmd => [ '--verbose', '-s', '-g', '--cookie', 'cookie=nomnom', '$url', ] },
    { cmd => [ '--verbose', '-s', '-g', '--cookie', 'cookie=nomnom; session=jam', '$url', ] },
    { cmd => [ '--verbose', '-s', '-g', '--cookie', 't/localserver-cookiejar.txt', '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '--cookie-jar', '$tempcookies', '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '-L', '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '-k', '$url', ],},
    #{ cmd => [ '--verbose', '-s', '-g', '--etag-compare', 't/2309.07208', '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '--etag-compare', 't/2309.07208', 'https://export.arxiv.org/pdf/2309.07208', ],},
);

run_curl_tests( @tests );
