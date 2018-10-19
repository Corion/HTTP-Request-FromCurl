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

my $server = Test::HTTP::LocalServer->spawn();
END { undef $server }
my $curl = 'curl';

my ($fh,$tempfile) = tempfile;
binmode $fh;
print $fh "This is a test\nMore test";
close $fh;
END { unlink $tempfile; }

my @tests = (
    { cmd => [ '--verbose', '-s', '$url' ] },
    { cmd => [ '--verbose', '-s', '-X', 'PATCH', '$url' ] },
    { cmd => [ '--verbose', '-s', '--head', '$url' ] },
    { cmd => [ '--verbose', '-s', '-H', 'Host: example.com', '$url' ] },
    { name => 'Multiple headers',
      cmd => [ '--verbose', '-s', '-H', 'Host: example.com', '-H','X-Example: foo', '$url' ] },
    { name => 'Duplicated header',
      cmd => [ '--verbose', '-s', '-H', 'X-Host: example.com', '-H','X-Host: www.example.com', '$url' ] },
    { name => 'Form parameters',
      ignore => [ 'Content-Length', 'Content-Type' ],
      cmd => [ '--verbose', '-s', '$url', '--get', '-F', 'name=Foo', '-F','version=1' ],
      version => '007061000', # earlier versions send an Expect: 100-continue header
      },
    { name => 'Append GET data',
      cmd => [ '--verbose', '-s', '$url', '--get', '-d', '{name:cool_event}' ] },
    { name => 'Append GET data to existing query',
      cmd => [ '--verbose', '-s', '$url?foo=bar', '--get', '-d', '{name:cool_event}' ] },
    { cmd => [ '--verbose', '-s', '$url', '-d', '{name:cool_event}' ] },
    { cmd => [ '--verbose', '-s', '--oauth2-bearer','someWeirdStuff', '$url' ],
      version => '007061000',
    },
    { cmd => [ '--verbose', '-s', '-A', 'www::mechanize/1.0', '$url' ],
    },
    { cmd => [ '--verbose', '-s', '--data-binary', '@$tempfile', '$url' ] },
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
            $res{ error } = "Couldn't find a method in curl output '$sent[0]'";
        };
        shift @sent;
        $res{ method } = $1;
        $res{ path } = $2;
        $res{ protocol } = $3;

        $res{ headers } = { map { /^> ([^:]+)\s*:\s*([^\r\n]*)$/ ? ($1 => $2) : () } @sent };
        $res{ response_body } = $stdout;
    } else {
        diag $stderr;
        $res{ error } = "Curl exit code $exit";
    };

    \%res
}

my $version = curl_version( $curl );

if( ! $version) {
    plan skip_all => "Couldn't find curl executable";
    exit;
};

diag "Curl version $version";
$HTTP::Request::FromCurl::default_headers{ 'User-Agent' } = "curl/$version";

my $cmp_version = sprintf "%03d%03d%03d", split /\./, $version;

sub request_identical_ok {
    my( $test ) = @_;
    local $TODO = $test->{todo};

    local $TODO = "curl $test->{version} required, we have $cmp_version"
        if $test->{version} and $cmp_version < $test->{version};

    my $cmd = [ @{ $test->{cmd} }];

    # Replace the dynamic parameters
    s!\$(url|port)!$server->$1!ge for @$cmd;
    s!\$(tempfile)!$tempfile!g for @$cmd;

    my $res = curl_request( @$cmd );
    if( $res->{error} ) {
        fail $test->{name};
        diag join " ", @$cmd;
        diag $res->{error};
        return;
    };

    my $r = HTTP::Request::FromCurl->new(
        argv => $cmd
    );

    my $name = $test->{name} || (join " ", @{ $test->{cmd}});
    my $status;
    if( $r->method ne $res->{method} ) {
        is $r->method, $res->{method}, $name;
        diag join " ", @{ $test->{cmd} };
        return;
    };

    if( url_decode($r->uri->path_query) ne $res->{path} ) {
        is url_decode($r->uri->path_query), $res->{path}, $name;
        diag join " ", @{ $test->{cmd} };
        return;
    };

    # There is no convenient way to get at the form data from curl
    #if( $r->content ne $res->{body} ) {
    #    is $r->content, $res->{body}, $name;
    #    diag join " ", @{ $test->{cmd} };
    #    return;
    #};

    my %got = $r->headers->flatten;
    if( $test->{ignore} ) {
        delete @got{ @{ $test->{ignore}}};
        delete @{$res->{headers}}{ @{ $test->{ignore}}};
    };

    is_deeply \%got, $res->{headers}, $name;

    # Now create a program from the request, run it and check that it still
    # sends the same request as curl does
};

plan tests => 0+@tests;

for my $test ( @tests ) {
    request_identical_ok( $test );
};

done_testing();
