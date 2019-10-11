#!perl
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;

use HTTP::Request::FromCurl;

our $VERSION = '0.13';

Getopt::Long::Configure('pass_through');
GetOptions(
    'no-tidy'  => \my $no_tidy,
    'type|t=s' => \my $ua_type,
) or pod2usage(2);

=head1 NAME

curl2lwp.pl - convert curl arguments to Perl code

=head1 SYNOPSIS

    curl2lwp.pl [options] [url] [url] ...

=head1 OPTIONS

=over 4

=item B<no-tidy>

Do not run the Perl code through L<HTML::Tidy>

=back

See curl(1) or L<https://curl.haxx.se/docs/manpage.html> for the official
documentation.

The following options are currently recognized:

=over 4

=item B<agent|A=s>

User-Agent

=item B<verbose|v>

Be verbose (ignored)

=item B<silent|s>

Be silent (ignored)

=item B<compressed>

Enable gzip compression

=item B<data|d=s@>

Supply (POST) data

=item B<data-binary=s@>

Supply (POST) data

=item B<referrer|e=s>

Set the C<Referer> header

=item B<form|F=s@>

Submit form data

=item B<get|G>

Issue a C<GET> request

=item B<header|H=s@>

Set the header

=item B<include|i>

Include response in output (ignored)

=item B<head|I>

Issue a C<HEAD> request

=item B<max-time>

Set a timeout for the request

=item B<keepalive> / B<no-keepalive>

Don't send a keep-alive header (ignored)

=item B<request|X=s>

Issue a custom request

=item B<oauth2-bearer=s>

Send an OAUTH2 bearer token

=item B<output|o=s>

Save output to a filename

=item B<user|u=s>

Set user and password for Basic authentication

=back

=cut

my $has_tidy;
BEGIN { eval { require Perl::Tidy; $has_tidy = 1; } }

my $request = HTTP::Request::FromCurl->new(
    argv => [ @ARGV ],
    read_files => 1,
) or exit 1; # Getopt::Long has already printed the error message

my $lwp = $request->as_snippet( type => $ua_type );

if( $has_tidy and ! $no_tidy) {
    my $formatted;
    Perl::Tidy::perltidy(
        source      => \$lwp,
        destination => \$formatted,
        argv        => [ '--no-memoize' ],
    ) or $lwp = $formatted;
}

print $lwp;
