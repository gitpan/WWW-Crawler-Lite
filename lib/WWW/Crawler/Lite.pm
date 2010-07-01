
package WWW::Crawler::Lite;

use strict;
use warnings 'all';
use LWP::UserAgent;
use HTTP::Request::Common;
use WWW::RobotRules;
use URI::URL;
use Time::HiRes 'usleep';
use Carp 'confess';

our $VERSION = '0.001';


sub new
{
  my ($class, %args) = @_;
  
  my $s = bless {
    url_pattern       => 'https?://.+',
    agent             => "WWW-Crawler-Lite/$VERSION $^O",
    http_accept       => [qw( text/html text/plain text/xhtml )],
    on_new_urls       => sub { my @urls = @_; },
    on_bad_url        => sub { my ($bad_url) = @_; },
    on_response       => sub { my ($url, $http_response) = @_; },
    on_link           => sub { my ($from, $to, $text) = @_ },
    delay_seconds     => 1,
    disallowed        => [ ],
    %args,
    urls              => { },
    _responded_urls   => { },
    RUNNING           => 1,
    IS_INITIALIZING   => 1,
  }, $class;
  $s->{rules} = WWW::RobotRules->new( $s->agent );
  
  return $s;
}# end new()

# Public read-only properties:
sub agent           { shift->{agent} }
sub url_pattern     { shift->{url_pattern} }
sub delay_seconds   { shift->{delay_seconds} }
sub http_accept     { @{ shift->{http_accept} } }
sub is_initializing { shift->{IS_INITIALIZING} }
sub is_running      { shift->{RUNNING} }
sub rules           { shift->{rules} }

# Public method:
sub stop { shift->{RUNNING} = 0 }


# Public getters/setters:
sub on_new_urls
{
  my $s = shift;
  
  return @_ ? $s->{on_new_urls} = shift : $s->{on_new_urls};
}# end on_new_urls()

sub on_bad_url
{
  my $s = shift;
  
  return @_ ? $s->{on_bad_url} = shift : $s->{on_bad_url};
}# end on_bad_url()

sub on_response
{
  my $s = shift;
  
  return @_ ? $s->{on_response} = shift : $s->{on_response};
}# end on_response()

sub on_link
{
  my $s = shift;
  
  return @_ ? $s->{on_link} = shift : $s->{on_link};
}# end on_link()


sub url_count
{
  my ($s) = @_;
  
  return scalar( keys %{ $s->{urls} } );
}# end url_count()


sub crawl
{
  my ($s, %args) = @_;
  
  confess "Require param 'url' not provided" unless $args{url};
  
  my $ua = LWP::UserAgent->new( agent => $s->agent );
  $ua->add_handler( response_header => sub {
    my ($response, $ua, $h) = @_;
    my ($type) = split /\;/, $response->header('content-type');
    grep { $type =~ m{\Q$_\E}i } $s->http_accept
      or die "unwanted mime type '$type'";
  });

  # Try to find robots.txt:
  my ($proto, $domain) = $args{url} =~ m{^(https?)://(.*?)/};
  eval {
    my $robots_url = "$proto://$domain/robots.txt";
    eval {
      my $res = $ua->request( GET $robots_url );
      $s->rules->parse( $robots_url, $res->content )
        if $res && $res->is_success && $res->content;
    };
  };
  
  $s->{urls}->{$args{url}} = 'taken';
  my $res = $ua->request( GET $args{url} );
  $s->_parse_result( $args{url}, $res );
  
  while( my $url = $s->_take_url() )
  {
    usleep( $s->delay_seconds * 1_000_000 );
    last unless $s->is_running;
    
    my $res = $ua->request( GET $url );
    my ($type) = split /\;/, $res->header('content-type');
    
    # Only parse responses that are of the correct MIME type:
    $s->_parse_result( $url, $res )
      if grep { $type =~ m{\Q$_\E}i } $s->http_accept;
  }# end while()
}# end crawl()


sub _take_url
{
  my ($s) = @_;
  
  my $url;
  SCOPE: {
    ($url) = grep { $s->{urls}->{$_} eq 'new' } keys %{ $s->{urls} }
      or return;
    $s->{urls}->{$url} = 'taken';
  };
  return $url;
}# end _take_url()


sub _parse_result
{
  my ($s, $url, $res) = @_;
  
  my $base = $res->base;
  my @new_urls = ( );

  (my $tmp = $res->content) =~ s{<a\s+.*?href\=(.*?)>(.*?)</a>}{
    my ($href,$anchortext) = ( $1, $2 );
    if( $anchortext =~ m/<img/ )
    {
      my ($alt) = join ". ", $anchortext =~ m/alt\="(.*?)"/sig;
      $anchortext =~ s/<img.*?>//sig;
      $anchortext .= ". $alt" if $alt;
    }# end if()
    $anchortext =~ s{</?.*?[/>]}{}sg;
    if( my ($quote) = $href =~ m/^(['"])/ )
    {
      ($href) = $href =~ m/^$quote(.*?)$quote/;
    }
    else
    {
      ($href) = $href =~ m/^([^\s+])/;
    }# end if()
    $href = "" unless defined($href);
    $href =~ s/\#.*$//;
    if( $href )
    {
      (my $new = url($href, $base)->abs->as_string) =~ s/\#.*$//;
      $anchortext =~ s/^\s+//s;
      $anchortext =~ s/\s+$//s;
      push @new_urls, { href => $new, text => $anchortext };
    }# end if()
    "";
  }isgxe;
  
  $s->on_response->( $url, $res );

  my %accepted_urls = ( );
  SCOPE: {
    my $pattern = $s->url_pattern;
    map {
      $accepted_urls{$_}++;
      $s->{urls}->{$_} ||= 'new';
    }
    grep {
      my $u = $_;
      m/$pattern/ &&
      ! exists($s->{urls}->{$u}) &&
      ! grep {
        $u =~ m{^https?://[^/]+?\Q$_\E.*}
      } @{$s->{disallowed}} &&
      $s->rules->allowed( $u )
    }
    map { $_->{href} } @new_urls;
  };
  
  # Send the event about this page linking to those other pages:
  my $pattern = $s->url_pattern;
  map {
    $s->on_link->( $url, $_->{href}, $_->{text} );
  }
  grep {
    my $u = $_;
    $u->{href} =~ m/$pattern/ &&
    ! grep {
      $u->{href} =~ m{^https?://[^/]+?\Q$_\E.*}
    } @{$s->{disallowed}} &&
    $s->rules->allowed( $u->{href} )
  } @new_urls;

  $s->on_new_urls->( keys(%accepted_urls) );
}# end _parse_result()

1;# return true:

=pod

=head1 NAME

WWW::Crawler::Lite - A single-threaded crawler/spider for the web.

=head1 SYNOPSIS

  my %pages = ( );
  my $pattern = 'https?://example\.com\/';
  my %links = ( );
  my $downloaded = 0;

  my $crawler;
  $crawler = WWW::Crawler::Lite->new(
    agent       => 'MySuperBot/1.0',
    url_pattern => $pattern,
    http_accept => [qw( text/plain text/html )],
    on_response => sub {
      my ($url, $res) = @_;
      
      warn "$url contains " . $res->content;
      $downloaded++;
      $crawler->stop() if $downloaded++ > 5;
    },
    on_link     => sub {
      my ($from, $to, $text) = @_;
      
      return if exists($pages{$to}) && $pages{$to} eq 'BAD';
      $pages{$to}++;
      $links{$to} ||= [ ];
      push @{$links{$to}}, { from => $from, text => $text };
    },
    on_bad_url => sub {
      my ($url) = @_;
      
      # Mark this url as 'bad':
      $pages{$url} = 'BAD';
    }
  );
  $crawler->crawl( url => "http://example.com/" );

  warn "DONE!!!!!";

  use Data::Dumper;
  map {
    warn "$_ ($pages{$_} incoming links) -> " . Dumper($links{$_})
  } sort keys %links;

=head1 DESCRIPTION

C<WWW::Crawler::Lite> is a single-threaded spider/crawler for the web.  It can
be used within a mod_perl, CGI or Catalyst-style environment because it does not
fork or use threads.

The callback-based interface is fast and simple, allowing you to focus on simply
processing the data that C<WWW::Crawler::Lite> extracts from the target website.

=head1 PUBLIC METHODS

=head2 new( %args )

Creates and returns a new C<WWW::Crawler::Lite> object.

The C<%args> hash is not required, but may contain the following elements:

=over 4

=item agent - String

Used as the user-agent string for HTTP requests.

B<Default Value:> - C<WWW-Crawler-Lite/$VERSION $^O>

=item url_pattern - RegExp or String

New links that do not match this pattern will not be added to the processing queue.

B<Default Value:> C<https?://.+>

=item http_accept - ArrayRef

This can be used to filter out unwanted responses.

B<Default Value:> C<[qw( text/html, text/plain, text/xhtml )]>

=item on_response($url, $response) - CodeRef

Called whenever a successful response is returned.

=item on_link($from, $to, $text) - CodeRef

Called whenever a new link is found.  Arguments are:

=over 8

=item $from

The URL that is linked *from*

=item $to

The URL that is linked *to*

=item $text

The anchor text (eg: The HTML within the link - <a href="...">B<This Text Here></a>)

=back

=item on_bad_url($url) - CodeRef

Called whenever an unsuccessful response is received.

=item delay_seconds - Number

Indicates the length of time (in seconds) that the crawler should pause before making
each request.  This can be useful when you want to spider a website, not launch
a denial of service attack on it.

=back

=head2 stop( )

Causes the crawler to stop processing its queue of URLs.

=head1 AUTHOR

John Drago <jdrago_999@yahoo.com>

=head1 COPYRIGHT

This software is Free software and may be used and redistributed under the same
terms as perl itself.

=cut

