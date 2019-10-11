#!perl
use strict;
use HTTP::Request::FromCurl;
use Test::More;
use Data::Dumper;
use Capture::Tiny 'capture';
use Test::HTTP::LocalServer;
use URL::Encode 'url_decode';
use File::Temp 'tempfile';

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

$Data::Dumper::Useqq = 1;

my $server = Test::HTTP::LocalServer->spawn(
#    debug => 1,
);
END { undef $server }
my $curl = 'curl';

my @erase;

sub tempname($content='') {
    my ($fh,$tempfile) = tempfile;
    if( $content ) {
        binmode $fh;
        print $fh $content;
        close $fh;
    };
    $tempfile
};
END { unlink @erase; }

my $tempfile = tempname("This is a test\nMore test");

my $tempcookies = tempname(<<COOKIES);
# Netscape HTTP Cookie File
# https://curl.haxx.se/docs/http-cookies.html
# This file was generated by libcurl! Edit at your own risk.

COOKIES

my $tempoutput = tempname();

my @tests = (
    { cmd => [ '--verbose', '-g', '-s', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '-X', 'PATCH', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '-XPATCH', '$url' ],
      name => 'short bundling options' },
    { cmd => [ '--verbose', '-g', '-s', '--head', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '-H', 'Host: example.com', '$url' ] },
    { name => 'Multiple headers',
      cmd => [ '--verbose', '-g', '-s', '-H', 'Host: example.com', '-H','X-Example: foo', '$url' ] },
    { name => 'Duplicated header',
      cmd => [ '--verbose', '-g', '-s', '-H', 'X-Host: example.com', '-H','X-Host: www.example.com', '$url' ] },
    { name => 'Form parameters',
      ignore => [ 'Content-Length', 'Content-Type' ],
      cmd => [ '--verbose', '-g', '-s', '$url', '--get', '-F', 'name=Foo', '-F','version=1' ],
      version => '007061000', # earlier versions send an Expect: 100-continue header
      },
    { name => 'Append GET data',
      cmd => [ '--verbose', '-g', '-s', '$url', '--get', '-d', '{name:cool_event}' ] },
    { name => 'Append GET data to existing query',
      cmd => [ '--verbose', '-g', '-s', '$url?foo=bar', '--get', '-d', '{name:cool_event}' ] },
    { cmd => [ '--verbose', '-g', '-s', '$url', '-d', '{name:cool_event}' ] },
    { cmd => [ '--verbose', '-g', '-s', '--oauth2-bearer','someWeirdStuff', '$url' ],
      version => '007061000',
    },
    { cmd => [ '--verbose', '-g', '-s', '-A', 'www::mechanize/1.0', '$url' ],
    },
    { cmd => [ '--verbose', '-g', '-s', '--data-binary', '@$tempfile', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '$url' ] },
    { cmd => [ '--verbose', '-g', '-s', '$url', '--max-time', 5 ] },
    { cmd => [ '--verbose', '-g', '-s', '$url', '--keepalive' ] },
    { cmd => [ '--verbose', '-g', '-s', '$url', '--no-keepalive' ] },
    { cmd => [ '--verbose', '-g', '-s', '$url', '--buffer' ] },
    { cmd => [ '--verbose', '-g', '-s', '-i', '$url' ],
      name => 'ignore --include option' },

    # Curl canonicalizes (HTTP) URLs by resolving "." and ".."
    { cmd => [ '--verbose', '-g', '-s', '$url/foo/..' ],
      version => '007061000', # At least 7.26 on Debian/wheezy and 7.29 on CentOS 7 fail to clean up the path
    },

    # perlmonks post xxx
    { cmd => [ '--verbose', '-s', '-g',
               '-X', 'POST',
               '-u', "apikey:xxx",
               '--header', "Content-Type: audio/flac",
               '--data-binary', '@$tempfile', '$url' ], },
    { cmd => [ '--verbose', '-s', '-g', '--compressed', '$url' ],
      ignore => ['Accept-Encoding'], # this somewhat defeats this test but at least
      # we check we don't crash. Available compressions might differ between
      # Curl and Compress::Zlib, so ...
    },
    { cmd => [ '--verbose', '-s', '-g', '-d', q!{'content': '\u6d4b\u8bd5'}!, '$url' ],
    },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--user', 'Corion:secret' ] },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--dump-header', $tempoutput ] },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--header', 'X-Test: test' ] },
    { cmd => [ '--verbose', '-s', '-g', '$url', '--request', 'TEST' ] },
    { cmd => [ '--verbose', '-s', '-g', '--cookie', 'cookie=nomnom', '$url', ] },
    { cmd => [ '--verbose', '-s', '-g', '--cookie', 'cookie=nomnom; session=jam', '$url', ] },
    { cmd => [ '--verbose', '-s', '-g', '--cookie', 't/localserver-cookiejar.txt', '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '--cookie-jar', $tempcookies, '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '-L', '$url', ],},
    { cmd => [ '--verbose', '-s', '-g', '-k', '$url', ],},
);

sub curl( @args ) {
    my ($stdout, $stderr, $exit) = capture {
        system( $curl, @args )
    };
}

sub curl_version( $curl ) {
    my( $stdout, undef, $exit ) = curl( '--version' );
    return undef if $exit;
    ($stdout =~ /^curl\s+([\d.]+)/)[0]
};

sub curl_request( @args ) {
    my ($stdout, $stderr, $exit) = curl(@args);

    my %res;

    if( ! $exit ) {

        # Let's ignore duplicate headers and the order:
        my @sent = grep {/^> /} split /\r?\n/, $stderr;
        if( !($sent[0] =~ /^> ([A-Z]+) (.*?) ([A-Z].*?)$/)) {
            $res{ error } = "Couldn't find a method in curl output '$sent[0]'. STDERR is $stderr";
        };
        shift @sent;
        $res{ method } = $1;
        $res{ path } = $2;
        $res{ protocol } = $3;

        $res{ headers } = { map { /^> ([^:]+)\s*:\s*([^\r\n]*)$/ ? ($1 => $2) : () } @sent };

        # Fix weirdo CentOS6 build of Curl which has a weirdo User-Agent header:
        if( exists $res{ headers }->{ 'User-Agent' }) {
            $res{ headers }->{ 'User-Agent' } =~ s!^(curl/7\.19\.7)\b.+!$1!;
        };

        $res{ response_body } = $stdout;
    } else {
        $res{ error } = "Curl exit code $exit";
        $res{ error_output } = $stderr;
    };

    \%res
}

sub compiles_ok( $code, $name ) {
    my( $fh, $tempname ) = tempfile( UNLINK => 1 );
    binmode $fh, ':raw';
    print $fh $code;
    close $fh;

    my ($stdout, $stderr, $exit) = capture(sub {
        system( $^X, '-Mblib', '-wc', $tempname );
    });

    if( $exit ) {
        diag $stderr;
        diag "Exit code: ", $exit;
        fail($name);
    } elsif( $stderr !~ /(^|\n)\Q$tempname\E syntax OK\s*$/) {
        diag $stderr;
        diag $code;
        fail($name);
    } else {
        pass($name);
    };
};

sub identical_headers_ok( $code, $expected_request, $name,
    %options
) {
    my $res;
    $res = eval $code
        or do { diag $@; };
    if( ref $res eq 'HASH' and $res->{status} >= 300 ) {
        diag Dumper $res;
    };
    my $log = $server->get_log;

    my @ignore_headers;
    @ignore_headers = $options{ ignore_headers } ? @{ $options{ ignore_headers } } : ();

    if( my $boundary = $options{ boundary }) {
        (my $old_boundary) = ($log =~ m!Content-Type: multipart/form-data; boundary=(.*?)$!ms);

        $log =~ s!\bboundary=\Q$old_boundary!boundary=$boundary!ms
            or die "Didn't replace $old_boundary in [[$log]]?!";
        $log =~ s!^\Q--$old_boundary!--$boundary!msg
            or die "Didn't replace '--$old_boundary' in [[$log]]?!";

        push @ignore_headers, 'Content-Length';
    };

    for my $h (@ignore_headers) {
        $log              =~ s!^$h: .*?\r?\n!!ms;
        $expected_request =~ s!^$h: .*?\r?\n!!ms;
    };

    my @log = split /\n/, $log;
    my @exp = split /\n/, $expected_request;

    is_deeply \@log, \@exp, $name
        or diag $log;
}

my $version = curl_version( $curl );

if( ! $version) {
    plan skip_all => "Couldn't find curl executable";
    exit;
};

note "Curl version $version";
$HTTP::Request::FromCurl::default_headers{ 'User-Agent' } = "curl/$version";

my $cmp_version = sprintf "%03d%03d%03d", split /\./, $version;

sub request_identical_ok {
    my( $test ) = @_;
    local $TODO = $test->{todo};

    local $TODO = "curl $test->{version} required, we have $cmp_version"
        if $test->{version} and $cmp_version < $test->{version};

    my $name = $test->{name} || (join " ", @{ $test->{cmd}});
    my $cmd = [ @{ $test->{cmd} }];

    # Replace the dynamic parameters
    s!\$(url|port)!$server->$1!ge for @$cmd;
    s!\$(tempfile)!$tempfile!g for @$cmd;

    my $res = curl_request( @$cmd );
    if( $res->{error} ) {
        my $skipcount = 3;
        my $skipreason = $res->{error};
        if( $res->{error_output} and $res->{error_output} =~ /\b(option .*?: the installed libcurl version doesn't support this\b)/) {
            $skipcount++;
            $skipreason = $1;

        } else {
            fail $test->{name};
            diag join " ", @$cmd;
            diag $res->{error_output};
        };
        SKIP: {
            skip $skipreason, $skipcount;
        };
        return;
    };
    my %log;
    $log{ curl } = $server->get_log;

    # Clean up some stuff that we will supply from our own values:
    my $compressed = join ", ", HTTP::Message::decodable();
    $log{ curl } =~ s!^Accept-Encoding: .*?$!Accept-Encoding: $compressed!ms;

    (my $boundary) = ($log{ curl } =~ m!Content-Type: multipart/form-data; boundary=(.*?)$!ms);

    my $r = HTTP::Request::FromCurl->new(
        argv => $cmd,
        read_files => 1,
    );

    my $status;
    if( ! $r ) {
        fail $name;
        SKIP: {
            skip "We can't check the request body", 2;
        };

    } elsif( $r->method ne $res->{method} ) {
        is $r->method, $res->{method}, $name;
        diag join " ", @{ $test->{cmd} };
        SKIP: {
            skip "We can't check the request body", 2;
        };
    } elsif( url_decode($r->uri->path_query) ne $res->{path} ) {
        is url_decode($r->uri->path_query), $res->{path}, $name ;
        diag join " ", @{ $test->{cmd} };
        SKIP: {
            skip "We can't check the request body", 2;
        };
    } else {
        # There is no convenient way to get at the form data from curl
        #if( $r->content ne $res->{body} ) {
        #    is $r->content, $res->{body}, $name;
        #    diag join " ", @{ $test->{cmd} };
        #    return;
        #};

        # If the request has a cookie jar we need to load+extract the cookie:
        if( my $j = $r->cookie_jar and $r->cookie_jar_options->{read}) {
            require HTTP::CookieJar;
            require Path::Tiny;
            Path::Tiny->import('path');
            my $jar = HTTP::CookieJar->new->load_cookies(path($j)->lines);
            if( my $c = $jar->cookie_header($server->url)) {
                $r->{headers}->{Cookie} = $c
            };
        };

        my %got = %{ $r->headers };
        if( $test->{ignore} ) {
            delete @got{ @{ $test->{ignore}}};
            delete @{$res->{headers}}{ @{ $test->{ignore}}};
        };

        is_deeply \%got, $res->{headers}, $name;

        # Now, also check that our HTTP::Request looks similar
        my $http_request = $r->as_request;
        my $payload = $http_request->content;

        is $payload, $r->body || '', "We don't munge the request body";
    };

    # Now create a program from the request, run it and check that it still
    # sends the same request as curl does

    if( $r ) {
        my $code = $r->as_snippet(type => 'LWP',
            preamble => ['use strict;','use LWP::UserAgent;']
        );
        compiles_ok( $code, "$name as LWP snippet compiles OK")
            or diag $code;

        identical_headers_ok( $code, $log{ curl },
            "We create (almost) the same headers with LWP",
            ignore_headers => ['Connection'],
            boundary       => $boundary,
        ) or diag $code;

        $code = $r->as_snippet(type => 'Tiny',
            preamble => ['use strict;','use HTTP::Tiny;']
        );
        compiles_ok( $code, "$name as HTTP::Tiny snippet compiles OK")
            or diag $code;
        identical_headers_ok( $code, $log{ curl },
            "We create (almost) the same headers with HTTP::Tiny",
            ignore_headers => ['Host'],
            boundary       => $boundary,
        ) or diag $code;

    } else {
        SKIP: {
            skip "Did not generate a request", 4;
        };
    };
};

plan tests => 0+@tests*6;

for my $test ( @tests ) {
    request_identical_ok( $test );
};

# Now check that we saved the correct cookies
#my $name = "Write cookies to file";
#if( open my $fh, '<', $tempcookies) {
#    my $content = join "", <$fh>;
#    like $content, qr/shazam2/, $name;
#} else {
#    fail $name;
#    diag "$tempcookies: $!";
#}

done_testing();
