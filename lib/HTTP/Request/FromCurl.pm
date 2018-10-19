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
    my $cmd = $options{ argv };
    
    GetOptionsFromArray( $cmd,
        'v|verbose'       => \my $verbose,
        's'               => \my $silent,
        'c|cookie-jar=s'  => \my $cookie_jar, # ignored
        'd|data=s'        => \my @post_data,    # ignored
        'e|referrer=s'    => \my $referrer,
        'F|form=s'        => \my @form_args,    # ignored
        'G|get'           => \my $get,
        'H|header=s'      => \my @headers,
        'I|head'          => \my $head,
        'X|request=s'     => \my $method,
        'oauth2-bearer=s' => \my $oauth2_bearer,
    ) or return;
    
    my ($uri) = @$cmd;
    my $body;
    $uri = URI->new( $uri );
 
    if( @form_args ) {
        $method = 'POST';
        push @headers, 'Content-Type: application/x-www-encoded';
        my $uri = URI->new('https://example.com');
        $uri->query_form( map { /^([^=])+=(.*)$/ ? ($1 => $2) : () } @form_args );
        $body = $uri->query;
        
    } elsif( $get ) {
        $method = 'GET';
        # Also, append the POST data to the URL
        if( @post_data ) {
            my $q = $uri->query;
            if( defined $q and length $q ) {
                $q .= "&";
            } else {
                $q = join "", @post_data;
            };
            $uri->query( $q );
        };
        
    } elsif( $head ) {
        $method = 'HEAD';
    } else {
        $method ||= 'GET';
    };

    if( defined $body ) {    
        push @headers, sprintf 'Content-Length: %d', length $body;
    };
        
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