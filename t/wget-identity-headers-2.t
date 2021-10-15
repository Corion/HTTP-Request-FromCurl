#!perl
use strict;
use HTTP::Request::FromWGet;

use lib 't';
use TestWGetIdentity 'run_wget_tests';

my @tests = (
    { cmd => [ '-O', '-', '--debug', '--no-cache', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '-O', '-', '--debug', '--cache', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '-O', '-', '--debug', '--referer', 'https://referer.example.com', '$url' ] },
    { cmd => [ '-O', '-', '--debug', '-U', 'mywget/1.0', '$url' ] },
    { cmd => [ '-O', '-', '--debug', '--user-agent', 'mywget/1.0', '$url' ] },
    { cmd => [ '-O', '-', '--debug', '--post-file', '$tempfile', '$url' ] },
    { cmd => [ '-O', '-', '--debug', '--post-data', 'msg=hello%20world&from=wget', '$url' ] },
);

run_wget_tests( @tests );
