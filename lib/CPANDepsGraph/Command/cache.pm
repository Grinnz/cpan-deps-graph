package CPANDepsGraph::Command::cache;

use 5.020;
use Mojo::Base 'Mojolicious::Command', -signatures;
use Mojo::Util 'getopt';

sub run ($self, @args) {
  getopt \@args,
    'all|a' => \my $all;

  my @dists = @args;

  if ($all) {
    my $mcpan = $self->app->mcpan;
    my $dists_rs = $mcpan->all('distributions', {fields => ['name']});
    @dists = ();
    while (my $dist = $dists_rs->next) {
      push @dists, $dist->name;
    }
  }
  
  foreach my $dist (@dists) {
    $self->app->cache_dist_deps($dist);
    print "Cached dependencies for $dist\n";
  }
}

1;
