#!perl
use strict;
use HTTP::Request::FromWGet;

use lib 't';
use TestWGetIdentity 'run_wget_tests';

my @tests = (
    { cmd => [ '--debug', '--header', 'Host: example.com', '$url', '-O', '-' ] },
    { name => 'Multiple headers',
      cmd => [ '--debug', '--header', 'Host: example.com', '--header','X-Example: foo', '$url', '-O', '-' ] },
    { name => 'Duplicated header',
      cmd => [  '--debug', '--header', 'X-Host: example.com', '--header','X-Host: www.example.com', '$url', '-O', '-' ] },
    { cmd => [  '--debug', , '--user-agent', 'www::mechanize/1.0', '$url', '-O', '-' ],
    },
    { cmd => [  '--debug', '$url', '--header', 'X-Test: test', '-O', '-' ] },
    { cmd => [  '--debug', '--compression', 'auto', '$url', '--header', 'X-Test: test', '-O', '-' ] },
    { cmd => [  '--debug', '--compression', 'gzip', '$url', '--header', 'X-Test: test', '-O', '-' ] },
    { cmd => [  '--debug', '--compression', 'none', '$url', '--header', 'X-Test: test', '-O', '-' ] },
    { cmd => [  '--debug', '--no-cache', '$url', '--header', 'X-Test: test', '-O', '-' ] },
    { cmd => [  '--debug', '--cache', '$url', '--header', 'X-Test: test', '-O', '-' ] },
);

run_wget_tests( @tests );
