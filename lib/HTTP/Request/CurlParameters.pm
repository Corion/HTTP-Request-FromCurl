package HTTP::Request::CurlParameters;
use strict;
use warnings;
use HTTP::Request;
use HTTP::Request::Common;
use URI;
use File::Spec::Unix;
use List::Util 'pairmap';
use PerlX::Maybe;

use Moo 2;
use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '0.01';

=head1 NAME

HTTP::Request::CurlParameters - container for a Curl-like HTTP request

=head1 SYNOPSIS

=head1 DESCRIPTION

Objects of this class are mostly created from L<HTTP::Request::FromCurl>.

=head1 METHODS

=head2 C<< ->new >>

Options:

=cut

has method => (
    is => 'ro',
    default => 'GET',
);

has uri => (
    is => 'ro',
    default => 'https://example.com',
);

has headers => (
    is => 'ro',
    default => sub { {} },
);

has credentials => (
    is => 'ro',
);

has post_data => (
    is => 'ro',
    default => sub { [] },
);

has body => (
    is => 'ro',
);

has form_args => (
    is => 'ro',
    default => sub { [] },
);

has output => (
    is => 'ro',
);

sub _build_body( $self ) {
    if( my $body = $self->body ) {
        $body =~ s!([\x00-\x1f"'\\])!sprintf '\\x%02x', ord $1!ge;
        return sprintf "'%s'", $body

    } else {
        # Sluuuurp
        my @post_data = map {
            /^\@(.*)/ ? do {
                             open my $fh, '<', $1
                                 or die "$1: $!";
                             local $/; # / for Filter::Simple
                             binmode $fh;
                             <$fh>
                           }
                      : $_
        } @{ $self->post_data };
        return join "", @post_data;
    }
};

#    if( @form_args) {
#        $method = 'POST';
#
#        my $req = HTTP::Request::Common::POST(
#            'https://example.com',
#            Content_Type => 'form-data',
#            Content => [ map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } @form_args ],
#        );
#        $body = $req->content;
#        unshift @headers, 'Content-Type: ' . join "; ", $req->headers->content_type;
#
#    } elsif( $options->{ get }) {
#        $method = 'GET';
#        # Also, append the POST data to the URL
#        if( @post_data ) {
#            my $q = $uri->query;
#            if( defined $q and length $q ) {
#                $q .= "&";
#            } else {
#                $q = "";
#            };
#            $q .= join "", @post_data;
#            $uri->query( $q );
#        };
#
#    } elsif( $options->{ head }) {
#        $method = 'HEAD';
#
#    } elsif( @post_data ) {
#        $method = 'POST';
#        $body = join "", @post_data;
#        unshift @headers, 'Content-Type: application/x-www-form-urlencoded';
#
#    } else {
#        $method ||= 'GET';
#    };

#    if( defined $body ) {
#        unshift @headers, sprintf 'Content-Length: %d', length $body;
#    };

#    my %headers = (
#        %default_headers,
#        'Host' => $uri->host_port,
#        (map { /^\s*([^:\s]+)\s*:\s*(.*)$/ ? ($1 => $2) : () } @headers),
#    );

=head2 C<< ->as_request >>

    $ua->request( $r->as_request );

Returns an equivalent L<HTTP::Request> object

=cut

sub as_request( $self ) {
    HTTP::Request->new(
        $self->method => $self->uri,
        [ %{ $self->headers } ],
        $self->_build_body(),
    )
};

sub _fill_snippet( $self, $snippet ) {
    # Doesn't parse parameters, yet
    $snippet =~ s!\$self->(\w+)!$self->$1!ge;
    $snippet
}

sub _pairlist( $self, $l, $prefix = "    " ) {
    return join ",\n",
        pairmap { qq{$prefix'$a' => '$b'} } @$l
}

sub _build_headers( $self, $prefix = "    " ) {
    # This is so we create the standard header order in our output
    my $h = HTTP::Headers->new( %{ $self->headers });
    $self->_pairlist([ $h->flatten ], $prefix);
}

=head2 C<< $r->as_snippet >>

    print $r->as_snippet;

Returns a code snippet that returns code to create an equivalent
L<HTTP::Request> object and to perform the request using L<WWW::Mechanize>.

This is mostly intended as a convenience function for creating Perl demo
snippets from C<curl> examples.

=cut

sub as_snippet( $self, %options ) {
    my $request_args = join ", ",
                                 '$r',
                           $self->_pairlist([
                               maybe ':content_file', $self->output
                           ], '')
                       ;
    my $setup_credentials = '';
    if( defined( my $credentials = $self->credentials )) {
        my( $user, $pass ) = split /:/, $credentials, 2;
        $setup_credentials = sprintf q{\n    $ua->credentials("%s","%s");\n},
            quotemeta $user,
            quotemeta $pass;
    };
    return <<SNIPPET;
    my \$ua = WWW::Mechanize->new();$setup_credentials
    my \$r = HTTP::Request->new(
        '@{[$self->method]}' => '@{[$self->uri]}',
        [
@{[$self->_build_headers('            ')]},
        ],
        @{[$self->_build_body()]}
    );
    my \$res = \$ua->request( $request_args );
SNIPPET
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