package HTTP::Request::FromCurl;
use strict;
use warnings;
use HTTP::Request;
use URI;
use Getopt::Long 'GetOptionsFromArray';

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

=head1 NAME

HTTP::Request::FromCurl - create a HTTP::Request from a curl command_line

=head1 SYNOPSIS

    my $req = HTTP::Request::FromCurl->new(
        # Note - curl itself may not appear
        argv => ['https://example.com'],
    );

    my $req = HTTP::Request::FromCurl->new(
        command => 'curl https://example.com',
    );

=cut

sub new( $class, %options ) {
    #my $cmd = $options{ command_line };
    
    my $cmd = $options{ argv };
    
    GetOptionsFromArray( $cmd,
        'v|verbose'    => \my $verbose,
        's'            => \my $silent,
        'c|cookie-jar=s' => \my $cookie_jar, # ignored
        'd|data=s'     => \my @post_data,    # ignored
        'e|referrer=s' => \my $referrer,
        'F|form=s'     => \my @form_args,    # ignored
        'G|get'        => \my $get,
        'H|header=s'   => \my @headers,
        'I|head'       => \my $head,
        'X|request=s'     => \my $method,
    ) or return;
    
    if( $get ) {
        $method = 'GET';
        # Also, append the POST data to the URL
    } elsif( $head ) {
        $method = 'HEAD';
    } else {
        $method ||= 'GET';
    };
    
    my ($uri) = @$cmd;
    my $body = undef;
    
    $uri = URI->new( $uri );
 
    my %headers = (
        'Accept' => '*/*',
        'Host' => $uri->host_port,
        'User-Agent' => 'curl/7.55.1',
        (map { /^\s*([^:\s]+)\s*:\s*(.*)$/ ? ($1 => $2) : () } @headers),
    );
    
    if( $referrer ) {
        $headers{ Referer } = $referrer;
    };
    
    HTTP::Request->new(
        $method => $uri,
        HTTP::Headers->new( %headers ),
        $body
    )
}

1;