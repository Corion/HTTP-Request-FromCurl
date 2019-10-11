#!perl
use strict;
use HTTP::Request::FromCurl;

use lib 't';
use TestCurlIdentity 'run_curl_tests';

my @tests = (
    { cmd => [ '--verbose', '-g', '-s', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '-X', 'PATCH', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '-XPATCH', '$url' ],
      name => 'short bundling options' },
    { cmd => [ '--verbose', '-g', '-s', '--head', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '-i', '$url' ],
      name => 'ignore --include option' },

    # Curl canonicalizes (HTTP) URLs by resolving "." and ".."
    { cmd => [ '--verbose', '-g', '-s', '$url/foo/..' ],
      version => '007061000', # At least 7.26 on Debian/wheezy and 7.29 on CentOS 7 fail to clean up the path
    },

    { cmd => [ '--verbose', '-s', '-g', '--compressed', '$url' ],
      ignore => ['Accept-Encoding'], # this somewhat defeats this test but at least
      # we check we don't crash. Available compressions might differ between
      # Curl and Compress::Zlib, so ...
    },
    { cmd => [ '--verbose', '-s', '-g', '-d', q!{'content': '\u6d4b\u8bd5'}!, '$url' ],
    },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--user', 'Corion:secret' ] },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--dump-header', '$tempoutput' ] },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--request', 'TEST' ] },
);

run_curl_tests( @tests );
