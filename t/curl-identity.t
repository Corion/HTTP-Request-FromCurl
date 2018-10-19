#!perl
use strict;
use HTTP::Request::FromCurl;
use Test::More;
use Data::Dumper;
use Capture::Tiny 'capture';
use Test::HTTP::LocalServer;
use URL::Encode 'url_decode';

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

my $server = Test::HTTP::LocalServer->spawn();
my $curl = 'curl';

my @tests = (
    { cmd => [ '--verbose', '-s', '"$url"' ] },
    { cmd => [ '--verbose', '-s', '-X', 'PATCH', '"$url"' ] },
    { cmd => [ '--verbose', '-s', '--head', '"$url"' ] },
    { cmd => [ '--verbose', '-s', '-H', 'Host: example.com', '"$url"' ] },
    { name => 'Multiple headers',
      cmd => [ '--verbose', '-s', '-H', 'Host: example.com', '-H','X-Example: foo', '"$url"' ] },
    { name => 'Form parameters',
      cmd => [ '--verbose', '-s', '"$url"', '--get', '-F', 'name=Foo', '-F','version=1' ] },
    { name => 'Append GET data',
      cmd => [ '--verbose', '-s', '"$url"', '--get', '-d', '{name:cool_event}' ] },
    { name => 'Append GET data to existing query',
      cmd => [ '--verbose', '-s', '"$url?foo=bar"', '--get', '-d', '{name:cool_event}' ] },
    { cmd => [ '--verbose', '-s', '"$url"', '-d', '{name:cool_event}' ] },
    { cmd => [ '--verbose', '-s', '--oauth2-bearer','someWeirdStuff', '"$url"' ] },
);

sub curl( @args ) {
    my ($stdout, $stderr, $exit) = capture {
        system( $curl, @args );
    };
}

sub curl_version( $curl ) {
    my( $stdout, undef, $exit ) = curl( '--version' );
    return undef if $exit;
    $stdout =~ /^curl\s+([\d.]+)/
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
diag "Curl version ", curl_version( $curl );

sub request_identical_ok {
    my( $test ) = @_;
    local $TODO = $test->{todo};
    # curl -Ivs http://example.com > /dev/null
    # --trace-ascii

    my $cmd = [ @{ $test->{cmd} }];

    # Replace the dynamic parameters
    s!\$(url|port)!$server->$1!ge for @$cmd;

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
        diag join " ", @$cmd;
        return;
    };

    if( url_decode($r->uri->path_query) ne $res->{path} ) {
        is url_decode($r->uri->path_query), $res->{path}, $name;
        diag join " ", @$cmd;
        return;
    };
    is_deeply +{ $r->headers->flatten }, $res->{headers}, $name;

    # Now create a program from the request, run it and check that it still
    # sends the same request as curl does
};

plan tests => 0+@tests;

for my $test ( @tests ) {
    request_identical_ok( $test );
};

done_testing();