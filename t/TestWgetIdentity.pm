package # hide from CPAN
    TestWgetIdentity;
use strict;
use HTTP::Request::FromWget;
use Test2::V0;
use Data::Dumper;
use Capture::Tiny 'capture';
use Test::HTTP::LocalServer;
use URI::Escape 'uri_unescape';
use File::Temp 'tempfile';
use Storable 'dclone';
use LWP::UserAgent;
use HTTP::Request;

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

our @EXPORT_OK = (qw(&run_wget_tests $server));
our $VERSION = '0.26';

$Data::Dumper::Useqq = 1;

our $server = Test::HTTP::LocalServer->spawn(
#debug => 1,
    request_pause => 0,
);
END { undef $server }
my $wget = 'wget';

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
# https://wget.haxx.se/docs/http-cookies.html
# This file was generated by libwget! Edit at your own risk.

COOKIES

my $tempoutput = tempname();

sub wget( @args ) {
    my ($stdout, $stderr, $exit) = capture {
        system( $wget, @args )
    };

    # This is mostly for testing the differences between Wget versions
    # $stderr =~ s!Wget/[\d.]+!Wget/1.2.3 (foo)!g;
    # $stdout =~ s!Wget/[\d.]+!Wget/1.2.3 (foo)!g;

    # This is for testing Wget not creating specific headers in some versions
    #$stderr =~ s!^Accept-Encoding: [^\r\n]*\r?\n!!msg;

    return ($stdout,$stderr,$exit)
}

sub wget_version( $wget ) {
    my( $stdout, undef, $exit ) = wget( '--version' );
    return undef if $exit;
    return ($stdout =~ /^GNU Wget\s+([\d.]+)/mi)[0]
};

sub wget_request( @args ) {
    my ($_stdout, $_stderr, $exit) = wget(@args);
    my @res;

    if( ! $exit ) {
        $_stderr =~ s!\r?\n!\r\n!g;
        $_stdout =~ s!\r?\n!\r\n!g;
        my @requests = grep { /^--20/ }  split /^(?=--20\d\d-[01]\d-\d\d)/m, $_stderr;
        for my $stderr (@requests) {
            my %res;

            # Let's ignore the order of the headers:
            if(! ($stderr =~ /^---request begin---\s+(.*?)\s+---request end---\r?\n/ms)) {
                $res{ error } = "Couldn't find request in wget output. STDERR is [[$stderr]]";
            } else {

                my $msg = HTTP::Request->parse("$1");

                $res{ method } = $msg->method;
                $res{ path } = $msg->uri->path;
                $res{ protocol } = $msg->protocol;

                $res{ headers } = +{ $msg->headers->flatten() };

                ## Fix FreeBSD build of wget which has "freebsd10.3 in the User-Agent header:
                if( exists $res{ headers }->{ 'User-Agent' }) {
                    $res{ headers }->{ 'User-Agent' } =~ s!^(Wget/[\d.]+).*!$1!;
                };
            };

            $res{ response_body } = $_stdout;

            push @res, \%res,
        };

        if( ! @requests) {
            diag "Weirdo output from wget that didn't produce any requests:";
            diag "STDOUT: [[$_stdout]]";
            diag "STDERR: [[$_stderr]]";
        };
    } else {
        my %res;
        $res{ error } = "wget exit code $exit";
        $res{ error_output } = $_stderr;
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

our $org_accept_encoding;

# Creates one test output
sub identical_headers_ok( $code, $expected_request, $name,
    %options
) {
    my $lived;
    $lived = eval $code
        or do { diag $@; };
    if( ref $lived eq 'HASH' and $lived->{status} >= 300 ) {
        diag Dumper $lived;
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

    if( ! $org_accept_encoding ) {
        push @ignore_headers, 'Accept-Encoding';
    };

    for my $h (@ignore_headers) {
        $log              =~ s!^$h: .*?\r?\n!!ms;
        $expected_request =~ s!^$h: .*?\r?\n!!ms;
    };

    # Fix up User-Agent header to consist only of "Wget/9.876.5":
    $log =~ s!^(User-Agent: Wget/[\d.]+)(?:\s.*)?$!$1!m;
    $expected_request =~ s!^(User-Agent: Wget/[\d.]+)(?:\s.*)?$!$1!m;;

    my @log = split /\n/, $log;
    my @exp = split /\n/, $expected_request;

    my $res = is \@log, \@exp, $name;
    if(! $res) {
        diag "Expected:";
        diag $expected_request;
        diag "Got:";
        diag $log;
    };
    return $res
}

my $version = wget_version( $wget ) // '';
#$version = '1.2.3';
my $cmp_version = sprintf "%03d%03d%03d", split /\./, $version;
if( ! $version) {
    plan skip_all => "Couldn't find wget executable";
    exit;

#    # https://wget.haxx.se/changes.html#7_37_0
#} elsif( $cmp_version < 7037000 and $server->url->host_port =~ /\[/ ) {
#    plan skip_all => sprintf "wget %s doesn't handle IPv6 hostnames like '%s'",
#                             $version, $server->url;
#    exit;
}

note "wget version $version ( $cmp_version )";
$HTTP::Request::FromWget::default_headers{ 'User-Agent' } = "Wget/$version";

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
        # There is no convenient way to get at the form data from wget
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
        if( my $h = $test->{ignore_headers} ) {
            $h = [$h] if ! ref $h;
            delete @got{ @{ $h }};
            delete @{$res->{headers}}{ @{ $h }};
        };

        ## Fix FreeBSD build of wget which has "freebsd10.3 in the User-Agent header:
        if( exists $res->{headers}->{ 'User-Agent' }) {
            $res->{ headers }->{ 'User-Agent' } =~ s!^(Wget/[\d\.]+)(?:\s.*)?!$1!;
        };

        # Fudge "accept" headers into "Accept" headers
        if( exists $got{accept} ) {
            $got{Accept} = delete $got{accept};
        };

        is \%got, $res->{headers}, $name
            or diag Dumper [\%got, $res->{headers}];

        # Now, also check that our HTTP::Request looks similar
        my $http_request = $r->as_request;
        my $payload = $http_request->content;

        is $payload, $r->body || '', "We don't munge the request body";
    };
}

sub request_identical_ok( $test ) {
    my $todo;

    if( $test->{todo} ) {
        $todo = todo($test->{todo});
    } elsif( $test->{version} and $cmp_version < $test->{version} ) {
        SKIP: {
            $todo = skip("wget $test->{version} required, we have $cmp_version", 10)
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
    my @res = wget_request( @$cmd );
    note sprintf "Made %d wget requests", 0+@res;
    # For consistency checking the skip counts
    #$res[0]->{error} = "Dummy error";
    if( $res[0]->{error} ) {
        # We run 2 tests for the setup and then 8 tests per request
        my $skipcount = 8;
        my $skipreason = $res[0]->{error};
        if(     $res[0]->{error_output}
            and $res[0]->{error_output} =~ /\b(option .*?: the installed libwget version doesn't support this\b)/) {
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
    #            warn "Fudging accept-encoding to '$compressed'";
    #$log =~ s!^Accept-Encoding: (.*?)$!Accept-Encoding: $compressed!msg;
    $log =~ m!^Accept-Encoding: (.*?)$!ms;

    $org_accept_encoding = $1;
    if( ! $org_accept_encoding ) {
        diag "This version of Wget does not set/send the Accept-Encoding header?!";
    };

    my @wget_log = split /^(?=Request:)/m, $log;
    note sprintf "Received %d wget requests", 0+@wget_log;

    my @r = HTTP::Request::FromWget->new(
        argv => $cmd,
        read_files => 1,
    );

    my @reconstructed_commandline = ('--debug', '-O', '-', map {"$_"} $r[0]->as_wget(wget => undef));
    note "Reconstructed as @reconstructed_commandline";

    my @reparse;
    my $lived = eval {
        @reparse = HTTP::Request::FromWget->new(
            argv => [@reconstructed_commandline],
            read_files => 1,
        );

        1;
    };
    if( ! $lived or @reparse == 0 ) {
        fail "Our reconstructed command line parses again";
        diag Dumper \@reconstructed_commandline;
        diag $@;
    } else {
        pass "Our reconstructed command line parses again"
    };

    # Well, no!
    # is_deeply \@reconstructed, $cmd, "Reconstructed command";
    # Check that the reconstructed command behaves identically
    my @reconstructed = wget_request( @reconstructed_commandline );

    # Can we maybe even loop over all requests?!
    # We need to fix our test count for numbers higher than 1
    for my $i ( 0..0 ) {
        if( $reconstructed[$i]->{error}) {
            SKIP: {
                diag Dumper $test->{cmd};
                diag Dumper \@reconstructed_commandline;
                diag Dumper $reconstructed[$i];
                fail "$name (reconstructed): wget error ($version): '$reconstructed[$i]->{error_output}'";
            };
        } else {

            # We will modify/fudge things a bit
            my $copy = dclone( $res[$i] );
            delete $copy->{response_body};
            delete $reconstructed[$i]->{response_body};
            if( exists $reconstructed[$i]->{headers}->{'Accept-Encoding'} ) {
                if( defined $org_accept_encoding ) {
                    $reconstructed[$i]->{headers}->{'Accept-Encoding'} = $org_accept_encoding;
                } else {
                    # Just to match what this old version of Wget sends
                    delete $reconstructed[$i]->{headers}->{'Accept-Encoding'};
                };
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
        my $wget_log = $wget_log[$i];
        (my $boundary) = ($wget_log =~ m!Content-Type: multipart/form-data; boundary=(.*?)$!ms);

        my $copy = dclone($r);
        if( exists $copy->{headers}->{'Accept-Encoding'} ) {
            if( defined $org_accept_encoding ) {
                $copy->{headers}->{'Accept-Encoding'} = $org_accept_encoding;
            } else {
                # This old version of Wget does not send Accept-Encoding: identity,
                # so we match that in our test suite
                delete $copy->{headers}->{'Accept-Encoding'};
            };
        };
        request_logs_identical_ok( $test, "$name (Logs)", $copy, $res );

        # Now create a program from the request, run it and check that it still
        # sends the same request as wget does

        if( $r ) {
            ## Fix FreeBSD build of wget which has "freebsd10.3 in the User-Agent header:
            if( exists $res->{headers}->{ 'User-Agent' }) {
                $wget_log =~ s!^(User-Agent:\s+Wget/[\d\.]+)( .*)?$!$1!m;
            };
            # Fix weirdo CentOS6 build of wget which has a weirdo User-Agent header:
            $wget_log =~ s!^(User-Agent:\s+Wget/[\d\.]+)( .*)?$!$1!m;
                #or die "Didn't find UA header in [$wget_log]?!";

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

            identical_headers_ok( $code, $wget_log,
                "We create (almost) the same headers with LWP",
                ignore_headers => ['Connection', @lwp_ignore, @$h],
                boundary       => $boundary,
            ) or diag $code;

            $code = $r->as_snippet(type => 'Tiny',
                preamble => ['use strict;','use HTTP::Tiny;']
            );
            compiles_ok( $code, "$name as HTTP::Tiny snippet compiles OK")
                or diag $code;
            identical_headers_ok( $code, $wget_log,
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

                identical_headers_ok( $code, $wget_log,
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

sub run_wget_tests( @tests ) {
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

    diag "Testing with wget version '$version'";

    for my $test ( @tests ) {
        request_identical_ok( $test );
    };
    done_testing();
};
