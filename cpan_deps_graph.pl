#!/usr/bin/env perl
use 5.020;
use Mojolicious::Lite -signatures;
use CPAN::DistnameInfo;
use Cpanel::JSON::XS ();
use HTTP::Simple 'getjson';
use MetaCPAN::Client;
use Module::CoreList;
use Mojo::JSON qw(from_json to_json);
use Mojo::Redis;
use Mojo::URL;
use Syntax::Keyword::Try;
use lib::relative 'lib';

$HTTP::Simple::JSON = Cpanel::JSON::XS->new->utf8->allow_dupkeys;

plugin 'Config' => {file => app->home->child('cpan_deps_graph.conf')};

push @{app->commands->namespaces}, 'CPANDepsGraph::Command';

my $mcpan = MetaCPAN::Client->new;
helper mcpan => sub ($c) { $mcpan };

my $url = app->config->{redis_url};
my $redis = Mojo::Redis->new($url);
helper redis => sub ($c) { $redis };

helper phases => sub ($c) { qw(configure build test runtime develop) };
helper relationships => sub ($c) { qw(requires recommends suggests) };

helper retrieve_dist_deps => sub ($c, $dist) {
  my $mcpan = $c->mcpan;
  my $release;
  try { $release = $mcpan->release($dist) } catch { return {} }
  return {} unless defined $release->dependency and @{$release->dependency};
  my %deps_by_module;
  foreach my $dep (@{$release->dependency}) {
    next if $dep->{module} eq 'perl';
    push @{$deps_by_module{$dep->{module}}}, $dep;
  }
  my @modules = keys %deps_by_module;
  my @package_data;
  while (my @chunk = splice @modules, 0, 100) {
    my $url = Mojo::URL->new('https://cpanmeta.grinnz.com/api/v2/packages')
      ->query(module => \@chunk);
    push @package_data, @{getjson("$url")->{data}};
  }
  my %deps;
  foreach my $package (@package_data) {
    my $module = $package->{module} // next;
    my $path = $package->{path} // next;
    my $distname = CPAN::DistnameInfo->new($path)->dist;
    next if $distname eq 'perl';
    push @{$deps{$_->{phase}}{$_->{relationship}}}, {dist => $distname, module => $module, version => $_->{version}} for @{$deps_by_module{$module}};
  }
  return \%deps;
};

helper cache_dist_deps => sub ($c, $dist, $deps = undef) {
  $deps //= $c->retrieve_dist_deps($dist);
  my $redis = $c->redis->db;
  $redis->multi;
  foreach my $phase ($c->phases) {
    foreach my $relationship ($c->relationships) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      $redis->del($key);
      my $modules = $deps->{$phase}{$relationship} // [];
      $redis->set($key, to_json $modules);
    }
  }
  $redis->exec;
};

helper cache_dist_deeply => sub ($c, $dist) {
  my %seen;
  my @to_check = $dist;
  while (defined(my $dist = shift @to_check)) {
    next if $seen{$dist}++;
    my $deps = $c->retrieve_dist_deps($dist);
    $c->cache_dist_deps($dist, $deps);
    foreach my $phase (keys %$deps) {
      foreach my $relationship (keys %{$deps->{$phase}}) {
        my $modules = $deps->{$phase}{$relationship};
        my %dists;
        $dists{$_->{dist}} = 1 for @$modules;
        push @to_check, keys %dists;
      }
    }
  }
};

helper get_dist_deps => sub ($c, $dist, $phases, $relationships, $perl_version = undef) {
  my $redis = $c->redis->db;
  my %all_deps;
  foreach my $phase (@$phases) {
    foreach my $relationship (@$relationships) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      my $deps_json = $redis->get($key);
      next unless defined $deps_json;
      my $deps;
      try { $deps = from_json $deps_json } catch { next }
      $all_deps{$_->{dist}} = 1 for grep { !Module::CoreList::is_core $_->{module}, $_->{version}, $perl_version } @$deps;
    }
  }
  return \%all_deps;
};

helper dist_dep_graph => sub ($c, $dist, $phases, $relationships, $perl_version = undef) {
  my %seen;
  my %children = ($dist => {});
  my @to_check = $dist;
  while (defined(my $dist = shift @to_check)) {
    next if $seen{$dist}++;
    my $dist_deps = $c->get_dist_deps($dist, $phases, $relationships, $perl_version);
    foreach my $dist_dep (keys %$dist_deps) {
      $children{$dist_dep} //= {};
      $children{$dist}{$dist_dep} = 1;
      push @to_check, $dist_dep;
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
  my $perl_version = $c->req->param('perl_version') // $];
  $c->render(json => $c->dist_dep_graph($dist, $phases, $relationships, $perl_version));
};

get '/graph';

app->start;
