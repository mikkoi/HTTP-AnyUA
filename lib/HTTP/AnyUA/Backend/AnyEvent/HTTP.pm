package HTTP::AnyUA::Backend::AnyEvent::HTTP;
# ABSTRACT: A unified programming interface for AnyEvent::HTTP

=head1 DESCRIPTION

This module adds support for the HTTP client L<AnyEvent::HTTP> to be used with the unified
programming interface provided by L<HTTP::AnyUA>.

=head1 SEE ALSO

=for :list
* L<HTTP::AnyUA::Backend>

=cut

use warnings;
use strict;

our $VERSION = '9999.999'; # VERSION

use parent 'HTTP::AnyUA::Backend';

use Future;
use HTTP::AnyUA::Util;


=method options

    $backend->options(\%options);

Get and set default arguments to C<http_request>.

=cut

sub options { @_ == 2 ? $_[0]->{options} = pop : $_[0]->{options} }

sub response_is_future { 1 }

sub request {
    my $self = shift;
    my ($method, $url, $args) = @_;

    my %opts    = $self->_munge_request($method, $url, $args);
    my $future  = Future->new;

    require AnyEvent::HTTP;
    AnyEvent::HTTP::http_request($method => $url, %opts, sub {
        my $resp = $self->_munge_response(@_, $args->{data_callback});

        if ($resp->{success}) {
            $future->done($resp);
        }
        else {
            $future->fail($resp);
        }
    });

    return $future;
}


sub _munge_request {
    my $self    = shift;
    my $method  = shift;
    my $url     = shift;
    my $args    = shift || {};

    my %opts = %{$self->options || {}};

    if (my $headers = $args->{headers}) {
        # munge headers
        my %headers;
        for my $header (keys %$headers) {
            my $value  = $headers->{$header};
            $value = join(', ', @$value) if ref($value) eq 'ARRAY';
            $headers{$header} = $value;
        }
        $opts{headers} = \%headers;
    }

    my @url_parts = HTTP::AnyUA::Util::split_url($url);
    if (my $auth = $url_parts[4] and !$opts{headers}{'authorization'}) {
        # handle auth in the URL
        require MIME::Base64;
        $opts{headers}{'authorization'} = 'Basic ' . MIME::Base64::encode_base64($auth, '');
    }

    my $content = HTTP::AnyUA::Util::coderef_content_to_string($args->{content});
    $opts{body} = $content if $content;

    if (my $data_cb = $args->{data_callback}) {
        # stream the response
        $opts{on_body} = sub {
            my $data = shift;
            $data_cb->($data, $self->_munge_response(undef, @_));
            1;  # continue
        };
    }

    return %opts;
}

sub _munge_response {
    my $self    = shift;
    my $data    = shift;
    my $headers = shift;
    my $data_cb = shift;

    # copy headers because http_request will continue to use the original
    my %headers = %$headers;

    my $code    = delete $headers{Status};
    my $reason  = delete $headers{Reason};
    my $url     = delete $headers{URL};

    my $resp = {
        success => 200 <= $code && $code <= 299,
        url     => $url,
        status  => $code,
        reason  => $reason,
        headers => \%headers,
    };

    my $version = delete $headers{HTTPVersion};
    $resp->{protocol} = "HTTP/$version" if $version;

    $resp->{content} = $data if $data && !$data_cb;

    my @redirects;
    my $redirect = delete $headers{Redirect};
    while ($redirect) {
        # delete pseudo-header first so redirects aren't recursively munged
        my $next = delete $redirect->[1]{Redirect};
        unshift @redirects, $self->_munge_response(@$redirect);
        $redirect = $next;
    }
    $resp->{redirects} = \@redirects if @redirects;

    if (590 <= $code && $code <= 599) {
        HTTP::AnyUA::Util::internal_exception($reason, $resp);
    }

    return $resp;
}

1;
