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
        command => 'https://example.com',
    );

    my $req = HTTP::Request::FromCurl->new(
        command_curl => 'curl -A mycurl/1.0 https://example.com',
    );

    my @requests = HTTP::Request::FromCurl->new(
        command_curl => 'curl -A mycurl/1.0 https://example.com https://www.example.com',
    );

=cut

our %default_headers = (
    'Accept' => '*/*',
    'User-Agent' => 'curl/7.55.1',
);

=head1 METHODS

=head2 C<< ->new >>

    my $req = HTTP::Request::FromCurl->new(
        # Note - curl itself may not appear
        argv => ['--agent', 'myscript/1.0', 'https://example.com'],
    );

    my $req = HTTP::Request::FromCurl->new(
        # Note - curl itself may not appear
        command => '--agent myscript/1.0 https://example.com',
    );

If the command generates multiple requests, they will be returned in list
context. In scalar context, the first request will be returned.

=cut

our @option_spec = (
    'agent|A=s',
    'verbose|v',
    'silent|s',
    #'c|cookie-jar=s',   # ignored
    'data|d=s@',
    'referrer|e=s',
    'form|F=s@',
    'get|G',
    'header|H=s@',
    'head|I',
    'request|X=s',
    'oauth2-bearer=s',
);

sub new( $class, %options ) {
    my $cmd = $options{ argv };

    if( $options{ command }) {
        require Text::ParseWords;
        $cmd = [ Text::ParseWords::shellwords($options{ command }) ];

    } elsif( $options{ command_curl }) {
        require Text::ParseWords;
        $cmd = [ Text::ParseWords::shellwords($options{ command_curl }) ];

        # remove the implicit curl command:
        shift @$cmd;
    };

    GetOptionsFromArray( $cmd,
        \my %curl_options,
        @option_spec,
    ) or return;

    return
        wantarray ? map { $class->_build_request( $_, \%curl_options ) } @$cmd
                  :       $class->_build_request( $cmd->[0], \%curl_options )
                  ;
    my ($uri) = @$cmd;
}

sub _build_request( $self, $uri, $options ) {
    my $body;
    $uri = URI->new( $uri );

    my @headers = @{ $options->{header} || []};
    my $method = $options->{request};
    my @post_data = @{ $options->{data} || []};
    my @form_args = @{ $options->{form} || []};

    if( @form_args) {
        $method = 'POST';

        my $req = HTTP::Request::Common::POST(
            'https://example.com',
            Content_Type => 'form-data',
            Content => [ map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } @form_args ],
        );
        $body = $req->content;
        unshift @headers, 'Content-Type: ' . join "; ", $req->headers->content_type;

    } elsif( $options->{ get }) {
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
        };

    } elsif( $options->{ head }) {
        $method = 'HEAD';

    } elsif( @post_data ) {
        $method = 'POST';
        $body = join "", @post_data;
        unshift @headers, 'Content-Type: application/x-www-form-urlencoded';

    } else {
        $method ||= 'GET';
    };

    if( defined $body ) {
        unshift @headers, sprintf 'Content-Length: %d', length $body;
    };

    if( $options->{ 'oauth2-bearer' } ) {
        push @headers, sprintf 'Authorization: Bearer %s', $options->{'oauth2-bearer'};
    };

    my %headers = (
        %default_headers,
        'Host' => $uri->host_port,
        (map { /^\s*([^:\s]+)\s*:\s*(.*)$/ ? ($1 => $2) : () } @headers),
    );

    if( defined $options->{ referrer }) {
        $headers{ Referer } = $options->{ 'referrer' };
    };

    if( defined $options->{ agent }) {
        $headers{ 'User-Agent' } = $options->{ 'agent' };
    };

    HTTP::Request->new(
        $method => $uri,
        HTTP::Headers->new( %headers ),
        $body
    )
};

1;

=head1 KNOWN DIFFERENCES

=head2 Different Content-Length for POST requests

=head2 Different delimiter for form data

The delimiter is built by L<HTTP::Message>, and C<curl> uses a different
mechanism to come up with a unique data delimiter. This results in differences
in the raw body content and the C<Content-Length> header.

=head1 MISSING FUNCTIONALITY

=over 4

=item *

Cookie files

Curl cookie files are neither read nor written

=item *

File uploads / content from files

Neither file uploads nor reading POST data from files is supported

=back

=cut