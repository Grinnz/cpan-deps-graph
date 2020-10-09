#!/usr/bin/env perl
use 5.020;
use Mojolicious::Lite -signatures;
use CPAN::DistnameInfo;
use HTTP::Simple 'getjson';
use List::UtilsBy 'uniq_by';
use MetaCPAN::Client;
use Module::CoreList;
use Mojo::JSON qw(from_json to_json);
use Mojo::Redis;
use Mojo::URL;
use Syntax::Keyword::Try;
use version;
use lib::relative 'lib';

our $VERSION = 'v1.1.0';
helper app_version => sub ($c) { $VERSION };

plugin 'Config' => {file => app->home->child('cpan_deps_graph.conf')};

if (defined(my $logfile = app->config->{logfile})) {
  app->log->with_roles('+Clearable')->path($logfile);
}

push @{app->commands->namespaces}, 'CPANDepsGraph::Command';

my $mcpan = MetaCPAN::Client->new;
helper mcpan => sub ($c) { $mcpan };

my $url = app->config->{redis_url};
my $redis = Mojo::Redis->new($url);
helper redis => sub ($c) { $redis };

helper phases => sub ($c) { +{map { ($_ => 1) } qw(configure build test runtime develop)} };
helper relationships => sub ($c) { +{map { ($_ => 1) } qw(requires recommends suggests)} };

helper retrieve_dist_deps => sub ($c, $dist, $dist_version = undef) {
  return {} if $dist eq 'Acme-DependOnEverything'; # not happening
  my $mcpan = $c->mcpan;
  my $release;
  try {
    $release = $mcpan->release({
      all => [
        { distribution => $dist },
        length($dist_version) ? { version => $dist_version } : { status => 'latest' },
      ],
    });
    $release = $release->next;
  } catch { return {} }
  return {} unless my @deps = @{ ($release && $release->dependency) || [] };
  my %deps_by_module;
  foreach my $dep (@deps) {
    next if $dep->{module} eq 'perl';
    next unless exists $c->phases->{$dep->{phase}};
    next unless exists $c->relationships->{$dep->{relationship}};
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
  foreach my $phase (keys %{$c->phases}) {
    foreach my $relationship (keys %{$c->relationships}) {
      my $key = "cpandeps:$dist:$phase:$relationship";
      $redis->del($key);
      my $modules = $deps->{$phase}{$relationship} // [];
      $redis->set($key, to_json $modules) if @$modules;
    }
  }
  $redis->set('cpandeps:last-update', time);
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

helper get_dist_deps => sub ($c, $dist, $phases, $relationships, $perl_version, $dist_version = undef) {
  $perl_version = $perl_version->numify;
  my $redis = $c->redis->db;
  my %all_deps;
  my $versioned_deps = length($dist_version) ? $c->retrieve_dist_deps($dist, $dist_version) : undef;
  foreach my $phase (@$phases) {
    foreach my $relationship (@$relationships) {
      my $deps;
      if ($versioned_deps) {
        $deps = $versioned_deps->{$phase}{$relationship} // [];
      } else {
        my $key = "cpandeps:$dist:$phase:$relationship";
        my $deps_json = $redis->get($key) // next;
        try { $deps = from_json $deps_json } catch { next }
      }
      foreach my $dep (@$deps) {
        try {
          next if Module::CoreList::is_core $dep->{module}, $dep->{version}, $perl_version;
        } catch {}
        $all_deps{$dep->{dist}} = 1;
      }
    }
  }
  return \%all_deps;
};

helper dist_dep_tree => sub ($c, $dist, $phases, $relationships, $perl_version, $dist_version = undef) {
  my %seen;
  my %deps;
  my @to_check = {dist => $dist, version => $dist_version}; # version only for initial
  while (defined(my $check = shift @to_check)) {
    my ($dist, $d_v) = @$check{qw(dist version)};
    next if $seen{$dist}++;
    $deps{$dist} = {};
    my $dist_deps = $c->get_dist_deps($dist, $phases, $relationships, $perl_version, $d_v);
    foreach my $dist_dep (keys %$dist_deps) {
      $deps{$dist}{$dist_dep} = 1;
      push @to_check, {dist => $dist_dep};
    }
  }
  return \%deps;
};

helper dist_dep_graph => sub ($c, $dist, $phases, $relationships, $perl_version, $dist_version = undef) {
  my $tree = $c->dist_dep_tree($dist, $phases, $relationships, $perl_version, $dist_version);
  my @nodes = map {
    {distribution => $_, children => [sort keys %{$tree->{$_}}]}
  } sort keys %$tree;
  return \@nodes;
};

helper dist_dep_table => sub ($c, $dist, $phases, $relationships, $perl_version, $dist_version = undef) {
  my $tree = $c->dist_dep_tree($dist, $phases, $relationships, $perl_version, $dist_version);
  my %seen;
  my @to_check = {dist => $dist, level => 1};
  my @table;
  while (defined(my $dep = shift @to_check)) {
    my ($dist, $level) = @$dep{'dist','level'};
    push @table, {dist => $dist, level => $level};
    next if $seen{$dist}++;
    my @deps = sort keys %{$tree->{$dist}};
    unshift @to_check, map { +{dist => $_, level => $level+1} } @deps;
  }
  return \@table;
};

get '/api/v1/deps' => sub ($c) {
  my $dist = $c->req->param('dist');
  my $dist_version = $c->req->param('dist_version');
  my $phases = $c->req->every_param('phase');
  $phases = ['runtime'] unless @$phases;
  my $relationships = $c->req->every_param('relationship');
  $relationships = ['requires'] unless @$relationships;
  my $perl_version = $c->req->param('perl_version') // "$]";
  try { $perl_version = version->parse($perl_version) } catch { $perl_version = version->parse("$]") }
  $c->render(json => $c->dist_dep_graph($dist, $phases, $relationships, $perl_version, $dist_version));
};

my @perl_versions = uniq_by { $_->normal } grep { $_ < '5.006' or !($_->{version}[1] % 2) }
  map { version->parse($_) } sort {$b <=> $a} keys %Module::CoreList::released;

get '/' => sub ($c) {
  $c->stash(perl_versions => \@perl_versions);
  $c->stash(dist => my $dist = $c->req->param('dist'));
  $c->stash(dist_version => my $dist_version = $c->req->param('dist_version'));
  if (length $dist and $dist =~ m/::/) {
    my $mcpan = $c->mcpan;
    try {
      my $module = $mcpan->module($dist, {fields => ['distribution']});
      return $c->redirect_to($c->url_with->query({dist => $module->distribution}));
    } catch {}
  }
  $c->stash(style => my $style = $c->req->param('style'));
  $c->stash(phase => my $phase = $c->req->param('phase'));
  $c->stash(recommends => my $recommends = $c->req->param('recommends'));
  $c->stash(suggests => my $suggests = $c->req->param('suggests'));
  my $perl_version = $c->req->param('perl_version') || "$]";
  try { $perl_version = version->parse($perl_version) } catch { $perl_version = version->parse("$]") }
  $c->stash(perl_version => $perl_version);
  if (($style // '') eq 'table' and length $dist) {
    my $phases = ['runtime'];
    $phase //= 'runtime';
    if ($phase eq 'build') {
      push @$phases, 'configure', 'build';
    } elsif ($phase eq 'test') {
      push @$phases, 'configure', 'build', 'test';
    } elsif ($phase eq 'configure') {
      $phases = ['configure'];
    }
    my $relationships = ['requires'];
    push @$relationships, 'recommends' if $recommends;
    push @$relationships, 'suggests' if $suggests;
    $c->stash(deps => $c->dist_dep_table($dist, $phases, $relationships, $perl_version, $dist_version));
  }
  $c->render;
} => 'graph';

app->start;
