package # hide from CPAN
    TestCurlIdentity;
use strict;
use HTTP::Request::FromCurl;
use Test2::V0;
use Data::Dumper;
use Capture::Tiny 'capture';
use Test::HTTP::LocalServer;
use URI::Escape 'uri_unescape';
use File::Temp 'tempfile';
use Storable 'dclone';
use LWP::UserAgent;

my $have_mojolicious;
BEGIN {
    if( eval { require Mojo::UserAgent; 1 }) {
        $have_mojolicious = 1;
    }
}

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = (qw(&run_curl_tests $server));
our $VERSION = '0.25';

$Data::Dumper::Useqq = 1;

our $server = Test::HTTP::LocalServer->spawn(
    request_pause => 0,
#debug => 1,
);
END { undef $server }
my $curl = $ENV{TEST_CURL_BIN} // 'curl';

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

sub curl( @args ) {
    my ($stdout, $stderr, $exit) = capture {
        system( $curl, @args )
    };

    return ($stdout,$stderr,$exit)
}

sub curl_version( $curl ) {
    my( $stdout, undef, $exit ) = curl( '--version' );
    return undef if $exit;
    return ($stdout =~ /^curl\s+([\d.]+)/)[0]
};

sub curl_request( @args ) {
    my ($stdout, $stderr, $exit) = curl(@args);
    my @res;

    if( ! $exit ) {
        my @requests = grep { /^> /m } split /^\* .*$/m, $stderr;
        for my $stderr (@requests) {
            my %res;
            # Let's ignore the order of the headers:
            my @sent = grep {/^> /} split /\r?\n/, $stderr;
            if( !($sent[0] =~ m!^> ([A-Z]+) (.*?) (HTTP/.*?)$!)) {
                $res{ error } = "Couldn't find a method in curl output '$sent[0]'. STDERR is [[$stderr]]";
            };
            shift @sent;
            $res{ method } = $1;
            $res{ path } = $2;
            $res{ protocol } = $3;

            $res{ headers } = {};
            for (map { /^> ([^:]+)\s*:\s*([^\r\n]*)$/ ? ([$1 => $2]) : () } @sent ) {
                my ($k,$v) = @$_;
                if( ! exists $res{ headers }->{ $k } ) {
                    $res{ headers }->{ $k } = $v;
                } else {
                    if( ! ref $res{ header }->{ $k }) {
                        $res{ headers }->{ $k } = [ $res{ headers }->{ $k } ];
                    };
                    push @{ $res{ headers }->{ $k } }, $v;
                };
            };
            #diag "Parsed curl Headers: " . Dumper $res{ headers };

            # Fix weirdo CentOS6 build of Curl which has a weirdo User-Agent header:
            if( exists $res{ headers }->{ 'User-Agent' }) {
                $res{ headers }->{ 'User-Agent' } =~ s!^(curl/7\.19\.7)\b.+!$1!;
            };

            $res{ response_body } = $stdout;

            push @res, \%res,
        };

        if( ! @requests) {
            diag "Weirdo output from curl that didn't produce any requests:";
            diag "STDOUT: [[$stdout]]";
            diag "STDERR: [[$stderr]]";
        };
    } else {
        my %res;
        $res{ error } = "Curl exit code $exit";
        $res{ error_output } = $stderr;
        push @res, \%res
    };

    return @res
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

# Creates one test output
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
        if( ! $old_boundary ) {
            diag "Old request didn't have a boundary?!";
            diag $log;
            return;
        };

        $log =~ s!\bboundary=\Q$old_boundary!boundary=$boundary!ms
            or die "Didn't replace $old_boundary to '$boundary' in [[$log]]?!";
        $log =~ s!^\Q--$old_boundary!--$boundary!msg
            or die "Didn't replace '--$old_boundary' to '$boundary' in [[$log]]?!";

        push @ignore_headers, 'Content-Length';
    };

    # Content-Length gets a special treatment for Content-Type application/x-www-form-urlencoded
    # because %20 and + are used to encode space between different versions of curl
    # 7.74.0 and prior use %20 , 7.78 seems to use +
    my $force_percent_encoding;
    if(     $expected_request =~ m!^Content-Type: application/x-www-form-urlencoded$!ms
        and $expected_request =~ /^Content-Length: (\d+)$/ms
    ) {
        my $len = $1;
        if( $log !~ /^Content-Length: $len$/ms ) {
            diag "Content-Length differs, likely due to different encoding for space (% vs. +)";
            push @ignore_headers, 'Content-Length';
            $force_percent_encoding = 1;
        };
    };

    for my $h (@ignore_headers) {
        $log              =~ s!^$h: .*?\r?\n!!ms;
        $expected_request =~ s!^$h: .*?\r?\n!!ms;
    };

    my @log = split /\n/, $log;
    my @exp = split /\n/, $expected_request;

    # Fix the bodies to use percent encoding if necessary:
    if( $force_percent_encoding ) {
        for my $res (\@log, \@exp) {
            # Find the start of the body:
            my $start = 1;
            $start++ while $res->[$start] !~ /^\s*$/;

            $res->[$start++] =~ s!\+!%20!g while $start < @$res;
        };
    };

    $res = is \@log, \@exp, $name;
    if(! $res) {
        diag "Expected:";
        diag $expected_request;
        diag "Got:";
        diag $log;
    };
    return $res
}

my $version = curl_version( $curl );
my $cmp_version = sprintf "%03d%03d%03d", split /\./, $version;
if( ! $version) {
    plan skip_all => "Couldn't find curl executable";
    exit;

    # https://curl.haxx.se/changes.html#7_37_0
} elsif( $cmp_version < 7037000 and $server->url->host_port =~ /\[/ ) {
    plan skip_all => sprintf "Curl %s doesn't handle IPv6 hostnames like '%s'",
                             $version, $server->url;
    exit;
}

note "Curl version $version";
$HTTP::Request::FromCurl::default_headers{ 'User-Agent' } = "curl/$version";

# Generates 2 OK stanzas
sub request_logs_identical_ok( $test, $name, $r, $res ) {
    my $status;
    if( ! $r ) {
        fail $name;
        SKIP: {
            skip "We can't check the request body", 1;
        };

    } elsif( $r->method ne $res->{method} ) {
        is $r->method, $res->{method}, $name;
        diag join " ", @{ $test->{cmd} };
        SKIP: {
            skip "We can't check the request body", 1;
        };
    } elsif( uri_unescape($r->uri->path_query) ne $res->{path} ) {
        is uri_unescape($r->uri->path_query), $res->{path}, $name ;
        diag join " ", @{ $test->{cmd} };
        SKIP: {
            skip "We can't check the request body", 1;
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
        my @ignore_headers;
        if( my $h = $test->{ignore_headers} ) {
            $h = [$h] if ! ref $h;
            @ignore_headers = @{ $h };
        };

        # Content-Length gets a special treatment for Content-Type application/x-www-form-urlencoded
        # because %20 and + are used to encode space between different versions of curl
        # 7.74.0 and prior use %20 , 7.78 seems to use +
        my $force_percent_encoding;
        if(     exists $got{ 'Content-Type'}
            and $got{'Content-Type'} =~ m!^application/x-www-form-urlencoded\b! ) {
                # Our Content-Length might be somewhat different
            if( exists $res->{headers}
                and $res->{headers}->{'Content-Type'} =~ m!^application/x-www-form-urlencoded\b! ) {
                # Force "%20" encoding on both parts if necessary:
                $force_percent_encoding = ($got{'Content-Length'} != $res->{headers}->{'Content-Length'});

                push @ignore_headers, 'Content-Length';
            };
        };

        delete @got{ @ignore_headers };
        delete @{$res->{headers}}{ @ignore_headers };

        # Fix weirdo CentOS6 build of Curl which has a weirdo User-Agent header:
        if( exists $res->{headers}->{ 'User-Agent' }) {
            $res->{headers}->{ 'User-Agent' } =~ s!^(curl/7\.19\.7)\b.+!$1!;
        };

        is \%got, $res->{headers}, $name
            or diag Dumper [\%got, $res->{headers}];

        # Now, also check that our HTTP::Request looks similar
        my $http_request = $r->as_request;
        my $payload = $http_request->content;
        my $body = $r->body;

        if( $force_percent_encoding ) {
            s!\+!%20!g
                for $payload, $body;
        };

        is $payload, $body || '', "We don't munge the request body";
    };
}

sub request_identical_ok( $test ) {
    my $todo;

    if( $test->{todo} ) {
        $todo = todo($test->{todo});
    } elsif( $test->{version} and $cmp_version < $test->{version} ) {
        SKIP: {
            $todo = skip("curl $test->{version} required, we have $cmp_version", 10)
        };
        return
    };

    my $name = $test->{name} || (join " ", @{ $test->{cmd}});
    my $cmd = [ @{ $test->{cmd} }];

    # Replace the dynamic parameters
    my $port = $server->url->port;
    for (@$cmd) {
        s!\$(url)\b!$server->$1!ge;
        s!\$(port)\b!$server->$1!ge;
        s!\$(host)\b!$server->url->host!ge;
        s!\$(tempfile)\b!$tempfile!g;
        s!\$(tempoutput)\b!$tempoutput!g;
        s!\$(tempcookies)\b!$tempcookies!g;
    };

    my $request_count = $test->{request_count} || 1;

    my @res = curl_request( @$cmd );
    note sprintf "Made %d curl requests", 0+@res;
    # For consistency checking the skip counts
    #$res[0]->{error} = "Dummy error";
    if( $res[0]->{error} ) {
        # We run 2 tests for the setup and then 6 tests per request
        my $skipcount = 8;
        my $skipreason = $res[0]->{error};
        if(     $res[0]->{error_output}
            and $res[0]->{error_output} =~ /\b(option .*?: the installed libcurl version doesn't support this\b)/) {
            $skipcount++;
            $skipreason = $1;

        } else {
            fail $name;
            diag join " ", @$cmd;
            diag $res[0]->{error_output};
        };
        SKIP: {
            # -1 for the fail() above
            skip $skipreason, 2 + ($skipcount * $request_count) -1;
        };
        return;
    };

    my $log = $server->get_log;
    # Clean up some stuff that we will supply from our own values:
    my $compressed = join ", ", HTTP::Message::decodable();
    $log =~ s!^Accept-Encoding: (.*?)$!Accept-Encoding: $compressed!msg;
    my $org_accept_encoding = $1;

    my @curl_log = split /^(?=Request:)/m, $log;
    note sprintf "Received %d curl requests", 0+@curl_log;

    my @r = HTTP::Request::FromCurl->new(
        argv => $cmd,
        read_files => 1,
    );

    my @reconstructed_commandline = ('--verbose', '--silent', map {"$_"} $r[0]->as_curl(curl => undef));
    note "Reconstructed as @reconstructed_commandline";

    for( @reconstructed_commandline ) {
        # fudge --data-* into --data if version is below (whatever)
        # 7.43: --data-raw
        # 7.18: --data-urlencode
        # 7.2:  --data-binary
        if( $_ eq '--data-raw' ) {
            $_ = '--data'
                if $cmp_version < 7043000;
        };
    };

    my @reparse;
    my $lived = eval {
        @reparse = HTTP::Request::FromCurl->new(
            argv => [@reconstructed_commandline],
            read_files => 1,
        );

        1;
    };
    if( ! $lived or @reparse == 0 ) {
        fail "Our reconstructed command line parses again";
        diag $@;
    } else {
        pass "Our reconstructed command line parses again"
    };

    # Well, no!
    # is_deeply \@reconstructed, $cmd, "Reconstructed command";
    # Check that the reconstructed command behaves identically
    my @reconstructed = curl_request( @reconstructed_commandline );

    # Can we maybe even loop over all requests?!
    # We need to fix our test count for numbers higher than 1
    for my $i ( 0..0 ) {
        if( $reconstructed[$i]->{error}) {
            SKIP: {
                diag Dumper $test->{cmd};
                diag Dumper \@reconstructed_commandline;
                diag Dumper $reconstructed[$i];
                fail "$name (reconstructed): Curl error ($version): '$reconstructed[$i]->{error_output}'";
            };
        } else {

            # We will modify/fudge things a bit
            my $copy = dclone( $res[$i] );
            delete $copy->{response_body};
            delete $reconstructed[$i]->{response_body};
            if( exists $reconstructed[$i]->{headers}->{'Accept-Encoding'} ) {
                $reconstructed[$i]->{headers}->{'Accept-Encoding'} = $org_accept_encoding;
            };

            # re-decode %7d and %7b to {}
            if( exists $reconstructed[$i]->{query} ) {
                $reconstructed[$i]->{query} =~ s!%7b!\{!gi;
                $reconstructed[$i]->{query} =~ s!%7d!\}!gi;
            };
            if( exists $reconstructed[$i]->{path} ) {
                $reconstructed[$i]->{path} =~ s!%7b!\{!gi;
                $reconstructed[$i]->{path} =~ s!%7d!\}!gi;
            };

            if(     exists $copy->{headers}->{'Content-Type'}
                and $copy->{headers}->{'Content-Type'} =~ m!^multipart/form-data\b! ) {
                    # Our Content-Length and Content-Type will be somewhat different
                if( $reconstructed[$i]->{headers}->{'Content-Type'} =~ m!^multipart/form-data\b! ) {
                    $copy->{headers}->{'Content-Length'} = 0;
                    $reconstructed[$i]->{headers}->{'Content-Length'} = 0;
                    $reconstructed[$i]->{headers}->{'Content-Type'} = $copy->{headers}->{'Content-Type'};
                };
            };

            # Content-Length gets a special treatment for Content-Type application/x-www-form-urlencoded
            # because %20 and + are used to encode space between different versions of curl
            # 7.74.0 and prior use %20 , 7.78 seems to use +
            if(     exists $copy->{headers}->{'Content-Type'}
                and $copy->{headers}->{'Content-Type'} =~ m!^application/x-www-form-urlencoded\b! ) {
                    # Our Content-Length might be somewhat different
                if( $reconstructed[$i]->{headers}->{'Content-Type'} =~ m!^application/x-www-form-urlencoded\b! ) {
                    $copy->{headers}->{'Content-Length'} = 0;
                    $reconstructed[$i]->{headers}->{'Content-Length'} = 0;
                    #$reconstructed[$i]->{headers}->{'Content-Type'} = $copy->{headers}->{'Content-Type'};

                    # Force "%20" encoding on both parts:
                };
            };

            # Ignore headers that the test says should be ignored
            if( my $h = $test->{ignore_headers} ) {
                $h = [$h] if ! ref $h;
                delete @{$reconstructed[$i]->{headers}}{ @{ $h }};
                delete @{$copy->{headers}}{ @{ $h }};
            };

            if( !is $reconstructed[$i], $copy, "$name (reconstructed)" ) {
                diag "Original command:";
                diag Dumper $test->{cmd};
                diag "Original request:";
                diag Dumper $copy;
                diag "Reconstructed command:";
                diag Dumper \@reconstructed_commandline;
                diag "Reconstructed request:";
                diag Dumper $reconstructed[$i];
            };
        };
    };

    # clean out the second round
    $server->get_log;

    my $requests = @r;
    if( $requests != @res ) {
        is $requests, 0+@res, "$name (requests)";
        diag join " ", @{ $test->{cmd} };
        diag Dumper \@r;
        SKIP: { skip "Weird number of requests", 0+@res*2; };
        return;
    };

    for my $i (0..$#r) {
        my $r = $r[$i];
        my $res = $res[$i];
        my $curl_log = $curl_log[$i];
        (my $boundary) = ($curl_log =~ m!Content-Type: multipart/form-data; boundary=(.*?)$!ms);

        my $copy = dclone($r);
        if( exists $copy->{headers}->{'Accept-Encoding'} ) {
            $copy->{headers}->{'Accept-Encoding'} = $org_accept_encoding;
        };

        request_logs_identical_ok( $test, $name, $copy, $res );

        # Now create a program from the request, run it and check that it still
        # sends the same request as curl does

        if( $r ) {
            # Fix weirdo CentOS6 build of Curl which has a weirdo User-Agent header:
            $curl_log =~ s!^(User-Agent:\s+curl/[\d\.]+)( .*)?$!$1!m;
                #or die "Didn't find UA header in [$curl_log]?!";

            my $code = $r->as_snippet(type => 'LWP',
                preamble => ['use strict;','use LWP::UserAgent;']
            );
            compiles_ok( $code, "$name as LWP snippet compiles OK")
                or diag $code;

            my @lwp_ignore;
            if( LWP::UserAgent->VERSION < 6.33 ) {
                push @lwp_ignore, 'TE';
            };

            my $h = $test->{ignore_headers} || [];
            $h = [$h]
                unless ref $h;

            identical_headers_ok( $code, $curl_log,
                "We create (almost) the same headers with LWP",
                ignore_headers => ['Connection', @lwp_ignore, @$h],
                boundary       => $boundary,
            ) or diag $code;

            $code = $r->as_snippet(type => 'Tiny',
                preamble => ['use strict;','use HTTP::Tiny;']
            );
            compiles_ok( $code, "$name as HTTP::Tiny snippet compiles OK")
                or diag $code;
            identical_headers_ok( $code, $curl_log,
                "We create (almost) the same headers with HTTP::Tiny",
                ignore_headers => ['Host','Connection', @$h],
                boundary       => $boundary,
            ) or diag $code;

            if( $have_mojolicious ) {
                my $code = $r->as_snippet(type => 'Mojolicious',
                    preamble => ['use strict;','use Mojo::UserAgent;']
                );
                compiles_ok( $code, "$name as Mojolicious snippet compiles OK")
                    or diag $code;

                my @mojolicious_ignore;

                my $h = $test->{ignore_headers} || [];
                $h = [$h]
                    unless ref $h;

                identical_headers_ok( $code, $curl_log,
                    "We create (almost) the same headers with Mojolicious",
                    ignore_headers => ['Host', 'Content-Length', 'Accept-Encoding', 'Connection', @mojolicious_ignore, @$h],
                    boundary       => $boundary,
                ) or diag $code;
            } else {
                SKIP: {
                    skip "Mojolicious not installed", 2;
                }
            }


        } else {
            SKIP: {
                skip "Did not generate a request", 6;
            };
        };
    };
};

sub run_curl_tests( @tests ) {
    my $testcount = 0;

    # Clean out environment variables that might mess up
    # the HTTP connection to a local host
    local @ENV{qw(
        HTTP_PROXY
        http_proxy
        HTTP_PROXY_ALL
        http_proxy_all
        HTTPS_PROXY
        https_proxy
        CGI_HTTP_PROXY
        ALL_PROXY
        all_proxy
    )};

    for( @tests ) {
        my $request_count = $_->{request_count} || 1;
        $testcount +=   2
                      + ($request_count * 8);
    };
    plan tests => $testcount;

    diag "Testing with curl version '$version'";

    for my $test ( @tests ) {
        request_identical_ok( $test );
    };
    done_testing();
};
