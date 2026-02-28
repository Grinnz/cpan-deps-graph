package CPANDepsGraph::Command::update_known;

use 5.020;
use Mojo::Base 'Mojolicious::Command', -signatures;

sub run ($self, @args) {
  my $cursor = $self->app->redis->cursor(scan => 0, match => 'cpandeps:*:*:*', count => 100);
  my $count = 0;
  while (my $keys = $cursor->next) {
    my @dists;
    foreach my $key (@$keys) {
      push @dists, $key =~ m/^cpandeps:([^:]+)/;
    }
    $count += $self->app->redis->db->sadd('cpandeps:known-dists', @dists);
  }
  print "Added $count known dists\n";
}

1;
