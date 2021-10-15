#!perl
use strict;
use HTTP::Request::FromWGet;

use lib 't';
use TestWGetIdentity 'run_wget_tests';

my @tests = (
    { cmd => [ '-O', '-', '--debug', '--header', 'Host: example.com', '$url' ] },
    { name => 'Multiple headers',
      cmd => [ '-O', '-', '--debug', '--header', 'Host: example.com', '--header','X-Example: foo', '$url' ] },
    { name => 'Duplicated header',
      cmd => [ '-O', '-', '--debug', '--header', 'X-Host: example.com', '--header','X-Host: www.example.com', '$url' ] },
    { cmd => [ '-O', '-', '--debug', , '--user-agent', 'www::mechanize/1.0', '$url' ],
    },
);

run_wget_tests( @tests );
