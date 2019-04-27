package CPANDepsGraph::Command::cache;

use 5.020;
use Mojo::Base 'Mojolicious::Command', -signatures;
use Mojo::Util 'getopt';
use Time::Piece;
use Time::Seconds;

sub run ($self, @args) {
  getopt \@args,
    'all|a' => \my $all,
    'since|s=s' => \my $since,
    'deeply|d' => \my $deeply;
  $deeply = 0 if $all;

  my @dists = @args;

  if ($all) {
    my $mcpan = $self->app->mcpan;
    my $dists_rs = $mcpan->all('distributions', {fields => ['name']});
    @dists = ();
    while (my $dist = $dists_rs->next) {
      push @dists, $dist->name;
    }
  } elsif (defined $since) {
    if ($since eq 'last') {
      my $redis = $self->app->redis->db;
      my $last_epoch = $redis->get('cpandeps:last-update') // time - ONE_DAY;
      $since = gmtime($last_epoch - 3 * ONE_HOUR)->datetime;
    }
    my $mcpan = $self->app->mcpan;
    my $releases_rs = $mcpan->all('releases', {
      fields => ['distribution'],
      es_filter => {and => [
        {range => {date => {gte => $since}}},
        {term => {status => 'latest'}},
      ]},
    });
    @dists = ();
    while (my $release = $releases_rs->next) {
      push @dists, $release->distribution;
    }
  }
  
  foreach my $dist (@dists) {
    if ($deeply) {
      $self->app->cache_dist_deeply($dist);
    } else {
      $self->app->cache_dist_deps($dist);
    }
    print "Cached dependencies for $dist\n";
  }
}

1;
