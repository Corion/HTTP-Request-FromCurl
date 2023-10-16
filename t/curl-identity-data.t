#!perl
use strict;
use HTTP::Request::FromCurl;

use lib 't';
use TestCurlIdentity 'run_curl_tests';

# For testing whether our test suite copes with %20 vs. + well:
#$URI::Escape::escapes{" "} = '+';

my @tests = (
    { cmd => [ '--verbose', '-g', '-s', '--data', '@$tempfile', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '--data-ascii', '@$tempfile', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '--data-binary', '@$tempfile', '$url' ],
      version => 7002000 },
    { cmd => [ '--verbose', '-g', '-s', '--data-raw', '@$tempfile', '$url' ],
      version => 7043000 },
    { cmd => [ '--verbose', '-g', '-s', '--data-urlencode', '@$tempfile', '$url' ],
      version => 7018000 },

    { cmd => [ '--verbose', '-g', '-s', '--form-string', 'foo=bar', '$url' ],
      },

    { cmd => [ '--verbose', '-g', '-s', '--form-escape',
                   #'-H', 'Content-Type: multipart/form-data',
                   '--form-string', "field1 name=bar\"",
                   '--form-string', "field2\\name=baz\"",
                   '--form-string', "field3%20name=bat+",
               '$url' ],
      version => 7081000 },

    { cmd => [ '--verbose', '-g', '-s', '--form-escape',
                   '-H', 'Content-Type: multipart/form-data',
                   '--form-string', "field1 name=bar\"",
                   '--form-string', "field2\\name=baz\"",
                   '--form-string', "field3%20name=bat+",
               '$url' ],
      version => 7081000 },

    { cmd => [ '--verbose', '-g', '-s', '--no-form-escape',
                   '--form-string', "field1 name=bar\"",
                   '--form-string', "field2\\name=baz\"",
                   '--form-string', "field3%20name=bat+",
               '$url' ],
      version => 7081000 },

);

run_curl_tests( @tests );
