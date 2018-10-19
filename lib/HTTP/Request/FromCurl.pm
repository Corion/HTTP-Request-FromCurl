package HTTP::Request::FromCurl;
use strict;
use warnings;
use HTTP::Request;
use HTTP::Request::Common;
use URI;
use Getopt::Long 'GetOptionsFromArray';

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '0.01';

=head1 NAME

HTTP::Request::FromCurl - create a HTTP::Request from a curl command line

=head1 SYNOPSIS

    my $req = HTTP::Request::FromCurl->new(
        # Note - curl itself may not appear
        argv => ['https://example.com'],
    );

    my $req = HTTP::Request::FromCurl->new(
        command => 'curl https://example.com',
    );

=cut

our %default_headers = (
    'Accept' => '*/*',
    'User-Agent' => 'curl/7.55.1',
);

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

        my $req = HTTP::Request::Common::POST(
            $uri,
            Content_Type => 'form-data',
            Content => [ map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } @form_args ],
        );
        $body = $req->content;
        push @headers, 'Content-Type: ' . join "; ", $req->headers->content_type;
        #warn "[[$body]]";

    } elsif( $get ) {
        $method = 'GET';
        # Also, append the POST data to the URL
        if( @post_data ) {
            my $q = $uri->query;
            if( defined $q and length $q ) {
                $q .= "&";
            } else {
                $q = "";
            };
            $q .= join "", @post_data;
            $uri->query( $q );
            @post_data = ();
        };

    } elsif( $head ) {
        $method = 'HEAD';

    } elsif( @post_data ) {
        $method = 'POST';
        $body = join "", @post_data;
        # multipart

    } else {
        $method ||= 'GET';
    };

    if( defined $body ) {
        push @headers, sprintf 'Content-Length: %d', length $body;
    };

    if( defined $oauth2_bearer ) {
        push @headers, sprintf 'Authorization: Bearer %s', $oauth2_bearer;
    };

    my %headers = (
        %default_headers,
        'Host' => $uri->host_port,
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

=head1 KNOWN DIFFERENCES

=head2 Different Content-Length for POST requests

=head2 Different delimiter for form data

The delimiter is built by L<HTTP::Message>, and C<curl> uses a different
mechanism to come up with a unique data delimiter. This results in differences
in the raw body content and the C<Content-Length> header.

=cut