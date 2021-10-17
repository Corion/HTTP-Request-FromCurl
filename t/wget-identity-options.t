#!perl
use strict;
use HTTP::Request::FromWget;

use lib 't';
use TestWgetIdentity 'run_wget_tests';

my @tests = (
    #{ cmd => [ '--verbose', '-g', '-s', '$url', '--max-time', 5 ] },
    { cmd => [ '-O', '-', '--debug', '--http-keep-alive', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '-O', '-', '--debug', '--no-http-keep-alive', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '-O', '-', '--debug', '--no-check-certificate', '$url' ] },
    #{ cmd => [ '--verbose', '-g', '-s', '$url', '--buffer' ] },
    #{ cmd => [ '--verbose', '-g', '-s', '$url', '--show-error' ] },

    { cmd => [ '-O', '-', '--debug', '--compression', 'auto', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '-O', '-', '--debug', '--compression', 'gzip', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '-O', '-', '--debug', '--compression', 'none', '$url', '--header', 'X-Test: test' ] },
);

run_wget_tests( @tests );
