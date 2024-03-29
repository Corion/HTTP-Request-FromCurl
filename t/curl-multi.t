#!perl
use strict;
use warnings;
use Test::More;
use HTTP::Request::FromCurl;

use lib 't';
use TestCurlIdentity 'run_curl_tests', '$server';

my @tests = (
    { cmd => [ '--verbose', '-s', '$url', '$url?foo=bar', ],
      ignore_headers => 'Cookie', # Curl handling of these is inconsistent
      request_count => 2,
    },
    { cmd => [ '--verbose', '-s', '$url', '--url', '$url?foo=bar', ],
      ignore_headers => 'Cookie', # Curl handling of these is inconsistent
      request_count => 2,
    },
    { cmd => [ '--verbose', '-s', '$url', '--junk-session-cookies', '$url?foo=bar', ],
      ignore_headers => 'Cookie', # Curl handling of these is inconsistent
      request_count => 2,
    },
    { cmd => [ '--verbose', '-s', '$url', '--next', '$url?foo=bar', ],
      version => 7036000,
      ignore_headers => 'Cookie', # Curl handling of these is inconsistent
      request_count => 2,
    },
);

run_curl_tests( @tests );
