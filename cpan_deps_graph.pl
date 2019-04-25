#!/usr/bin/env perl
use 5.020;
use Mojolicious::Lite -signatures;
use MetaCPAN::Client;
use Mojo::Redis;
use Syntax::Keyword::Try;
use lib::relative 'lib';

plugin 'Config' => {file => app->home->child('cpan_deps_graph.conf')};

push @{app->commands->namespaces}, 'CPANDepsGraph::Command';

my $mcpan = MetaCPAN::Client->new;
helper mcpan => sub ($c) { $mcpan };

my $redis = Mojo::Redis->new;
helper redis => sub ($c) { $redis };

helper phases => sub ($c) { qw(configure build test runtime develop) };
helper relationships => sub ($c) { qw(requires recommends suggests) };

helper retrieve_dist_deps => sub ($c, $dist) {
  my $mcpan = $c->mcpan;
  my $release;
  try { $release = $mcpan->release($dist) } catch { return {} }
  my %deps_by_module;
  foreach my $dep (@{$release->dependency}) {
    push @{$deps_by_module{$dep->{module}}}, $dep;
  }
  my $dep_releases = $mcpan->release({all => [
    {status => 'latest'},
    {either => [map { +{provides => $_} } keys %deps_by_module]},
    {not => [{distribution => 'perl'}]},
  ]}, {fields => ['distribution','provides']});
  my %deps;
  while (my $dep_release = $dep_releases->next) {
    foreach my $module (grep { exists $deps_by_module{$_} } @{$dep_release->provides}) {
      $deps{$_->{phase}}{$_->{relationship}}{$dep_release->distribution} = 1 for @{$deps_by_module{$module}};
    }
  }
  return \%deps;
};

helper cache_dist_deps => sub ($c, $dist) {
  my $deps = $c->retrieve_dist_deps($dist);
  my $redis = $c->redis->db;
  $redis->multi;
  foreach my $phase ($c->phases) {
    foreach my $relationship ($c->relationships) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      $redis->del($key);
      my $dists = $deps->{$phase}{$relationship};
      $redis->lpush($key, keys %$dists) if defined $dists and keys %$dists;
    }
  }
  $redis->exec;
};

helper get_dist_deps => sub ($c, $dist, $phases, $relationships) {
  my $redis = $c->redis->db;
  my %deps;
  foreach my $phase (@$phases) {
    foreach my $relationship (@$relationships) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      $deps{$_} = 1 for @{$redis->lrange($key, 0, -1)};
    }
  }
  return [sort keys %deps];
};

helper dist_dep_graph => sub ($c, $dist, $phases, $relationships) {
  my %seen;
  my %children = ($dist => {});
  my @to_check = $dist;
  while (defined(my $dist = shift @to_check)) {
    next if $seen{$dist}++;
    my $dist_deps = $c->get_dist_deps($dist, $phases, $relationships);
    foreach my $dep (@$dist_deps) {
      $children{$dep} //= {};
      $children{$dist}{$dep} = 1;
      push @to_check, $dep;
    }
  }
  my @nodes = map {
    {distribution => $_, children => [sort keys %{$children{$_}}]}
  } sort keys %children;
  return \@nodes;
};

get '/api/v1/deps' => sub ($c) {
  my $dist = $c->req->param('dist');
  my $phases = $c->req->every_param('phase');
  $phases = [$c->phases] unless @$phases;
  my $relationships = $c->req->every_param('relationship');
  $relationships = [$c->relationships] unless @$relationships;
  $c->render(json => $c->dist_dep_graph($dist, $phases, $relationships));
};

get '/graph';

app->start;
