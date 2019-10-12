package # hide from CPAN
    TestCurlIdentity;
use strict;
use HTTP::Request::FromCurl;
use Test::More;
use Data::Dumper;
use Capture::Tiny 'capture';
use Test::HTTP::LocalServer;
use URL::Encode 'url_decode';
use File::Temp 'tempfile';
use LWP::UserAgent;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';

our @EXPORT_OK = (qw(&run_curl_tests $server));
our $VERSION = '0.13';

$Data::Dumper::Useqq = 1;

our $server = Test::HTTP::LocalServer->spawn(
#debug => 1,
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

    my @res;

    if( ! $exit ) {
        my @requests = grep { /^> /m } split /^\* .*$/m, $stderr;
        for my $stderr (@requests) {
            my %res;
            # Let's ignore the order of the headers:
            my @sent = grep {/^> /} split /\r?\n/, $stderr;
            if( !($sent[0] =~ m!^> ([A-Z]+) (.*?) (HTTP/.*?)$!)) {
                $res{ error } = "Couldn't find a method in curl output '$sent[0]'. STDERR is $stderr";
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
    } else {
        my %res;
        $res{ error } = "Curl exit code $exit";
        $res{ error_output } = $stderr;
        push @res, \%res
    };

    @res
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
    my $port = $server->url->port;
    # For testing of globbing on an IPv6 system
    #s!\$(url)\b!http://localhost:$port!g for @$cmd;
    s!\$(url)\b!$server->$1!ge for @$cmd;
    s!\$(port)\b!$server->$1!ge for @$cmd;
    s!\$(tempfile)\b!$tempfile!g for @$cmd;
    s!\$(tempoutput)\b!$tempoutput!g for @$cmd;
    s!\$(tempcookies)\b!$tempcookies!g for @$cmd;

    my @res = curl_request( @$cmd );
    note sprintf "Made %d curl requests", 0+@res;
    if( $res[0]->{error} ) {
        my $skipcount = 5;
        my $skipreason = $res[0]->{error};
        if(     $res[0]->{error_output}
            and $res[0]->{error_output} =~ /\b(option .*?: the installed libcurl version doesn't support this\b)/) {
            $skipcount++;
            $skipreason = $1;

        } else {
            fail $test->{name};
            diag join " ", @$cmd;
            diag $res[0]->{error_output};
        };
        SKIP: {
            skip $skipreason, $skipcount;
        };
        return;
    };

    my $log = $server->get_log;
    # Clean up some stuff that we will supply from our own values:
    my $compressed = join ", ", HTTP::Message::decodable();
    $log =~ s!^Accept-Encoding: .*?$!Accept-Encoding: $compressed!msg;

    my @curl_log = split /^(?=Request:)/m, $log;
    note sprintf "Received %d curl requests", 0+@curl_log;


    my @r = HTTP::Request::FromCurl->new(
        argv => $cmd,
        read_files => 1,
    );

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

            is_deeply \%got, $res->{headers}, $name
                or diag Dumper [\%got, $res->{headers}];

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

            my @lwp_ignore;
            if( LWP::UserAgent->VERSION < 6.33 ) {
                push @lwp_ignore, 'TE';
            };

            identical_headers_ok( $code, $curl_log,
                "We create (almost) the same headers with LWP",
                ignore_headers => ['Connection', @lwp_ignore],
                boundary       => $boundary,
            ) or diag $code;

            $code = $r->as_snippet(type => 'Tiny',
                preamble => ['use strict;','use HTTP::Tiny;']
            );
            compiles_ok( $code, "$name as HTTP::Tiny snippet compiles OK")
                or diag $code;
            identical_headers_ok( $code, $curl_log,
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
};

sub run_curl_tests( @tests ) {
    my $testcount = @tests * 6;
    if( ! ref $tests[-1] ) {
        $testcount = pop @tests;
    };
    plan tests => $testcount;

    for my $test ( @tests ) {
        request_identical_ok( $test );
    };
    done_testing();
};
