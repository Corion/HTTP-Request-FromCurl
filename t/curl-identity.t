#!perl
use strict;
use HTTP::Request::FromCurl;
use Test::More;
use Data::Dumper;
use Capture::Tiny 'capture';
use Test::HTTP::LocalServer;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

my $server = Test::HTTP::LocalServer->spawn();
my $curl = 'curl';

my @tests = (
    { cmd => [ '--verbose', '-s', '"$url"' ] },
    { cmd => [ '--verbose', '-s', '--head', '"$url"' ] },
    { cmd => [ '--verbose', '-s', '-H', 'Host: example.com', '"$url"' ] },
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
        if( !($sent[0] =~ /^> ([A-Z]+) (.*?)$/)) {
            $res{ error } = "Couldn't find a method in curl output '$sent[0]'";
        };
        shift @sent;
        $res{ method } = $1;
        $res{ path } = $2;
        
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
    
    diag join " ", @$cmd;
    my $res = curl_request( @$cmd );
    if( $res->{error} ) {
        fail $test->{name};
        diag $res->{error};
        return;
    };
    
    my $r = HTTP::Request::FromCurl->new(
        argv => $cmd
    );
    
    my $status;
    if( $r->method ne $res->{method} ) {
        is $r->method, $res->{method}, $test->{name};
        return;
    };
    is_deeply +{ $r->headers->flatten }, $res->{headers}, $test->{name};
};

plan tests => 0+@tests;

for my $test ( @tests ) {
    request_identical_ok( $test );
};

done_testing();