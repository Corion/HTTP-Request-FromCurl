package HTTP::Request::FromCurl;
use strict;
use warnings;
use HTTP::Request;
use HTTP::Request::Common;
use URI;
use Getopt::Long 'GetOptionsFromArray';
use File::Spec::Unix;
use HTTP::Request::CurlParameters;
use PerlX::Maybe;
use MIME::Base64 'encode_base64';

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
    # Send the requests
    for my $r (@requests) {
        $ua->request( $r )
    }

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
context. In scalar context, only the first request will be returned.

=head2 C<< ->squash_uri( $uri ) >>

    my $uri = HTTP::Request::FromCurl->squash_uri(
        URI->new( 'https://example.com/foo/bar/..' )
    );
    # https://example.com/foo/

Helper method to clean up relative path elements from the URI the same way
that curl does.
    
=head1 GLOBAL VARIABLES

=head2 C<< %default_headers >>

Contains the default headers added to every request

=cut

our %default_headers = (
    'Accept' => '*/*',
    'User-Agent' => 'curl/7.55.1',
);

=head2 C<< @option_spec >>

Contains the L<Getopt::Long> specification of the recognized command line
parameters

=cut

our @option_spec = (
    'agent|A=s',
    'verbose|v',
    'silent|s',
    #'c|cookie-jar=s',   # ignored
    'data|d=s@',
    'data-binary=s@',
    'referrer|e=s',
    'form|F=s@',
    'get|G',
    'header|H=s@',
    'head|I',
    'no-keepalive',
    'request|X=s',
    'oauth2-bearer=s',
    'output|o=s',
    'user|u=s',
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
}

sub squash_uri( $class, $uri ) {
    my $u = $uri->clone;
    my @segments = $u->path_segments;

    if( $segments[-1] and ($segments[-1] eq '..' or $segments[-1] eq '.' ) ) {
        push @segments, '';
    };

    @segments = grep { $_ ne '.' } @segments;

    # While we find a pair ( "foo", ".." ) remove that pair
    while( grep { $_ eq '..' } @segments ) {
        my $i = 0;
        while( $i < $#segments ) {
            if( $segments[$i] ne '..' and $segments[$i+1] eq '..') {
                splice @segments, $i, 2;
            } else {
                $i++
            };
        };
    };

    if( @segments < 2 ) {
        @segments = ('','');
    };

    $u->path_segments( @segments );
    return $u
}

sub _build_request( $self, $uri, $options ) {
    my $body;
    $uri = URI->new( $uri );

    my @headers = @{ $options->{header} || []};
    my $method = $options->{request};
    my @post_data = @{ $options->{data} || $options->{'data-binary'} || []};
    my @form_args = @{ $options->{form} || []};

    $uri = $self->squash_uri( $uri );

    # Sluuuurp
    @post_data = map {
        /^\@(.*)/ ? do {
                         open my $fh, '<', $1
                             or die "$1: $!";
                         local $/;
                         binmode $fh;
                         <$fh>
                       }
                  : $_
    } @post_data;

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

    if( $options->{ 'user' } ) {
        if(    $options->{anyauth}
            || $options->{ntlm}
            || $options->{negotiate}
            ) {
            # Nothing to do here, just let LWP::UserAgent do its thing
            # This means one additional request to fetch the appropriate
            # 401 response asking for credentials, but ...
        } else {
            # $options->{basic} or none at all
            my $info = delete $options->{'user'};
            # We need to bake this into the header here?!
            push @headers, sprintf 'Authorization: Basic %s', encode_base64( $info );
        }
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

    HTTP::Request::CurlParameters->new({
        method => $method,
        uri    => $uri,
        headers => \%headers,
        body   => $body,
        maybe credentials => $options->{ user },
        maybe output => $options->{ output },
    });
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

While file uploads and reading POST data from files are supported, the content
is slurped into memory completely. This can be problematic for large files
and little available memory.

=item *

Sequence expansion

Curl supports speficying sequences of URLs such as
C< https://example.com/[1-100] > , which expands to
C< https://example.com/1 >, C< https://example.com/2 > ...
C< https://example.com/100 >

This is not (yet) supported.

=item *

List expansion

Curl supports speficying sequences of URLs such as
C< https://{www,ftp}.example.com/ > , which expands to
C< https://www.example.com/ >, C< https://ftp.example.com/ >.

This is not (yet) supported.

=item *

Multiple sets of parameters from the command line

Curl supports the C<< --next >> command line switch which resets
parameters for the next URL.

This is not (yet) supported.

=back

=cut