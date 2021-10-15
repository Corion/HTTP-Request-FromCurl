package HTTP::Request::FromWGet;
use strict;
use warnings;
use HTTP::Request;
use HTTP::Request::Common;
use URI;
use URI::Escape;
use Getopt::Long;
use File::Spec::Unix;
use HTTP::Request::CurlParameters;
use HTTP::Request::Generator 'generate_requests';
use PerlX::Maybe;
use MIME::Base64 'encode_base64';

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

our $VERSION = '0.26';

=head1 NAME

HTTP::Request::FromWGet - create a HTTP::Request from a wget command line

=head1 SYNOPSIS

    my $req = HTTP::Request::FromWGet->new(
        # Note - wget itself may not appear
        argv => ['https://example.com'],
    );

    my $req = HTTP::Request::FromWGet->new(
        command => 'https://example.com',
    );

    my $req = HTTP::Request::FromWGet->new(
        command_wget => 'wget -A mywget/1.0 https://example.com',
    );

    my @requests = HTTP::Request::FromWGet->new(
        command_wget => 'wget -A mywget/1.0 https://example.com https://www.example.com',
    );
    # Send the requests
    for my $r (@requests) {
        $ua->request( $r->as_request )
    }

=head1 RATIONALE

C<wget> command lines are found everywhere in documentation. The Firefox
developer tools can also copy network requests as C<wget> command lines from
the network panel. This module enables converting these to Perl code.

=head1 METHODS

=head2 C<< ->new >>

    my $req = HTTP::Request::FromWGet->new(
        # Note - wget itself may not appear
        argv => ['--user-agent', 'myscript/1.0', 'https://example.com'],
    );

    my $req = HTTP::Request::FromWGet->new(
        # Note - wget itself may not appear
        command => '--user-agent myscript/1.0 https://example.com',
    );

The constructor returns one or more L<HTTP::Request::CurlParameters> objects
that encapsulate the parameters. If the command generates multiple requests,
they will be returned in list context. In scalar context, only the first request
will be returned.

    my $req = HTTP::Request::FromWGet->new(
        command => '--data-binary @/etc/passwd https://example.com',
        read_files => 1,
    );

=head3 Options

=over 4

=item B<argv>

An arrayref of commands as could be given in C< @ARGV >.

=item B<command>

A scalar in a command line, excluding the C<wget> command

=item B<command_wget>

A scalar in a command line, including the C<wget> command

=item B<read_files>

Do read in the content of files specified with (for example)
C<< --data=@/etc/passwd >>. The default is to not read the contents of files
specified this way.

=back

=head2 C<< ->squash_uri( $uri ) >>

    my $uri = HTTP::Request::FromWGet->squash_uri(
        URI->new( 'https://example.com/foo/bar/..' )
    );
    # https://example.com/foo/

Helper method to clean up relative path elements from the URI the same way
that wget does.

=head1 GLOBAL VARIABLES

=head2 C<< %default_headers >>

Contains the default headers added to every request

=cut

our %default_headers = (
    'Accept'     => '*/*',
    'Accept-Encoding' => 'identity',
    'User-Agent' => 'Wget/1.21',
    'Connection' => 'Keep-Alive',
);

=head2 C<< @option_spec >>

Contains the L<Getopt::Long> specification of the recognized command line
parameters.

The following C<wget> options are recognized but largely ignored:

=over 4

XXX

If you want to keep session cookies between subsequent requests, you need to
provide a cookie jar in your user agent.

=back

=cut

our @option_spec = (
    'user-agent|U=s',
    'referer=s',
    'verbose|v',         # ignored
    'show-error|S',      # ignored
    'fail|f',            # ignored
    'silent|s',          # ignored
    'buffer!',
    'compression=s',
    'cookie|b=s',
    'load-cookies|c=s',
    'post-data=s@',
    'post-file=s@',
    'body-data=s@',
    'body-file=s@',
    'content-disposition=s',
    'auth-no-challenge', # ignored
    'referer=s',
    'form|F=s@',
    'header|H=s@',
    'method=s',
    'include|i',         # ignored
    'insecure|k',
    'location|L',        # ignored, we always follow redirects
    'max-time|m=s',
    'http-keepalive!',
    'cache!',            # XXX unimplemented, adds cache headers
    'progress-bar|#',    # ignored
    'http-user|u=s',
    'http-password|u=s',
    'output-file|O=s',   # ignored
    'debug',             # ignored
);

sub new( $class, %options ) {
    my $cmd = $options{ argv };

    if( $options{ command }) {
        require Text::ParseWords;
        $cmd = [ Text::ParseWords::shellwords($options{ command }) ];

    } elsif( $options{ command_wget }) {
        require Text::ParseWords;
        $cmd = [ Text::ParseWords::shellwords($options{ command_wget }) ];

        # remove the implicit wget command:
        shift @$cmd;
    };

    for (@$cmd) {
        $_ = '--next'
            if $_ eq '-:'; # GetOptions does not like "next|:" as specification
    };

    my $p = Getopt::Long::Parser->new(
        config => [ 'bundling', 'no_auto_abbrev', 'no_ignore_case_always' ],
    );
    $p->getoptionsfromarray( $cmd,
        \my %wget_options,
        @option_spec,
    ) or return;

    return
        wantarray ? map { $class->_build_request( $_, \%wget_options, %options ) } @$cmd
                  :       ($class->_build_request( $cmd->[0], \%wget_options, %options ))[0]
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

# Ugh - wget doesn't allow for multiple headers of the same name on the command line
sub _add_header( $self, $headers, $h, $value ) {
    #if( exists $headers->{ $h }) {
    #    if (!ref( $headers->{ $h })) {
    #        $headers->{ $h } = [ $headers->{ $h }];
    #    }
    #    push @{ $headers->{ $h } }, $value;
    #} else {
        $headers->{ $h } = $value;
    #}
}

sub _set_header( $self, $headers, $h, $value ) {
    $headers->{ $h } = $value;
}

sub _maybe_read_data_file( $self, $read_files, $data ) {
    my $res;
    if( $read_files ) {
        if( $data =~ /^\@(.*)/ ) {
            open my $fh, '<', $1
                or die "$1: $!";
            local $/; # / for Filter::Simple
            binmode $fh;
            $res = <$fh>
        } else {
            $res = $_
        }
    } else {
        $res = ($data =~ /^\@(.*)/)
             ? "... contents of $1 ..."
             : $data
    }
    return $res
}

sub _build_request( $self, $uri, $options, %build_options ) {
    my $body;

    my @headers = @{ $options->{header} || []};
    my $method = $options->{request};
    # Ideally, we shouldn't sort the data but process it in-order
    my @post_read_data = (@{ $options->{'data'} || []},
                          @{ $options->{'data-ascii'} || [] }
                         );
                         ;
    my @post_raw_data = @{ $options->{'data-raw'} || [] },
                    ;
    my @post_urlencode_data = @{ $options->{'data-urlencode'} || [] };
    my @post_binary_data = @{ $options->{'data-binary'} || [] };
    my @form_args = @{ $options->{form} || []};

    # expand the URI here if wanted
    my @uris = ($uri);
    if( ! $options->{ globoff }) {
        @uris = map { $_->{url} } generate_requests( pattern => shift @uris, limit => $build_options{ limit } );
    }

    my @res;
    for my $uri (@uris) {
        $uri = URI->new( $uri );
        $uri = $self->squash_uri( $uri );

        my $host = $uri->can( 'host_port' ) ? $uri->host_port : "$uri";

        # Stuff we use unless nothing else hits
        my %request_default_headers = %default_headers;

        # Sluuuurp
        # Thous should be hoisted out of the loop
        @post_binary_data = map {
            $self->_maybe_read_data_file( $build_options{ read_files }, $_ );
        } @post_binary_data;

        @post_read_data = map {
            my $v = $self->_maybe_read_data_file( $build_options{ read_files }, $_ );
            $v =~ s![\r\n]!!g;
            $v
        } @post_read_data;

        @post_urlencode_data = map {
            m/\A([^@=]*)([=@])?(.*)\z/sm
                or die "This should never happen";
            my ($name, $op, $content) = ($1,$2,$3);
            if(! $op) {
                $content = $name;
            } elsif( $op eq '@' ) {
                $content = "$op$content";
            };
            if( defined $name and length $name ) {
                $name .= '=';
            } else {
                $name = '';
            };
            my $v = $self->_maybe_read_data_file( $build_options{ read_files }, $content );
            $name . uri_escape( $v )
        } @post_urlencode_data;

        my $data;
        if(    @post_read_data
                or @post_binary_data
                or @post_raw_data
                or @post_urlencode_data
        ) {
            $data = join "&",
                @post_read_data,
                @post_binary_data,
                @post_raw_data,
                @post_urlencode_data
                ;
        };

        if( @form_args) {
            $method = 'POST';

            my $req = HTTP::Request::Common::POST(
                'https://example.com',
                Content_Type => 'form-data',
                Content => [ map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } @form_args ],
            );
            $body = $req->content;
            $request_default_headers{ 'Content-Type' } = join "; ", $req->headers->content_type;

        } elsif( $options->{ get }) {
            $method = 'GET';
            # Also, append the POST data to the URL
            if( $data ) {
                my $q = $uri->query;
                if( defined $q and length $q ) {
                    $q .= "&";
                } else {
                    $q = "";
                };
                $q .= $data;
                $uri->query( $q );
            };

        } elsif( $options->{ head }) {
            $method = 'HEAD';

        } elsif( defined $data ) {
            $method = 'POST';
            $body = $data;
            $request_default_headers{ 'Content-Type' } = 'application/x-www-form-urlencoded';

        } else {
            $method ||= 'GET';
        };

        if( defined $body ) {
            $request_default_headers{ 'Content-Length' } = length $body;
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

        my %headers;
        for my $kv (
            (map { /^\s*([^:\s]+)\s*:\s*(.*)$/ ? [$1 => $2] : () } @headers),) {
                $self->_add_header( \%headers, @$kv );
        };

        if( defined $options->{ 'user-agent' }) {
            $self->_set_header( \%headers, "User-Agent", $options->{ 'user-agent' } );
        };

        if( defined $options->{ referrer }) {
            $self->_set_header( \%headers, "Referer" => $options->{ 'referrer' } );
        };

        for my $k (keys %request_default_headers) {
            if( ! $headers{ $k }) {
                $self->_add_header( \%headers, $k, $request_default_headers{ $k });
            };
        };
        if( ! $headers{ 'Host' }) {
            $self->_add_header( \%headers, 'Host' => $host );
        };

        if( defined $options->{ 'cookie-jar' }) {
                $options->{'cookie-jar-options'}->{ 'write' } = 1;
        };

        if( defined( my $c = $options->{ cookie })) {
            if( $c =~ /=/ ) {
                $headers{ Cookie } = $options->{ 'cookie' };
            } else {
                $options->{'cookie-jar'} = $c;
                $options->{'cookie-jar-options'}->{ 'read' } = 1;
            };
        };

        if( my $c = $options->{ compression }) {
            if( $c =~ /^(gzip|auto)$/ ) {
                # my $compressions = HTTP::Message::decodable();
                $self->_set_header( \%headers, 'Accept-Encoding' => 'gzip' );
            };
        };

        push @res, HTTP::Request::CurlParameters->new({
            method => $method,
            uri    => $uri,
            headers => \%headers,
            body   => $body,
            maybe credentials => $options->{ user },
            maybe output => $options->{ output },
            maybe timeout => $options->{ 'max-time' },
            maybe cookie_jar => $options->{'cookie-jar'},
            maybe cookie_jar_options => $options->{'cookie-jar-options'},
            maybe insecure => $options->{'insecure'},
            maybe show_error => $options->{'show_error'},
            maybe fail => $options->{'fail'},
        });
    }

    return @res
};

1;

=head1 LIVE DEMO

L<https://corion.net/curl2lwp.psgi>

=head1 KNOWN DIFFERENCES

=head2 Incompatible cookie jar formats

Until somebody writes a robust Netscape cookie file parser and proper loading
and storage for L<HTTP::CookieJar>, this module will not be able to load and
save files in the format that wget uses.

=head2 Loading/saving cookie jars is the job of the UA

You're expected to instruct your UA to load/save cookie jars:

    use Path::Tiny;
    use HTTP::CookieJar::LWP;

    if( my $cookies = $r->cookie_jar ) {
        $ua->cookie_jar( HTTP::CookieJar::LWP->new()->load_cookies(
            path($cookies)->lines
        ));
    };

=head2 Different Content-Length for POST requests

=head2 Different delimiter for form data

The delimiter is built by L<HTTP::Message>, and C<wget> uses a different
mechanism to come up with a unique data delimiter. This results in differences
in the raw body content and the C<Content-Length> header.

=head1 MISSING FUNCTIONALITY

=over 4

=item *

File uploads / content from files

While file uploads and reading POST data from files are supported, the content
is slurped into memory completely. This can be problematic for large files
and little available memory.


=back

=head1 SEE ALSO

L<HTTP::Request::AsCurl> - for the inverse function

The module HTTP::Request::AsCurl likely also implements a much better version
of C<< ->as_curl >> than this module.

=head1 REPOSITORY

The public repository of this module is
L<http://github.com/Corion/HTTP-Request-FromWGet>.

=head1 SUPPORT

The public support forum of this module is
L<https://perlmonks.org/>.

=head1 BUG TRACKER

Please report bugs in this module via the Github bug queue at
L<https://github.com/Corion/HTTP-Request-FromWGet/issues>

=head1 AUTHOR

Max Maischein C<corion@cpan.org>

=head1 COPYRIGHT (c)

Copyright 2018-2021 by Max Maischein C<corion@cpan.org>.

=head1 LICENSE

This module is released under the same terms as Perl itself.

=cut
