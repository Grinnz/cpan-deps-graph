function populate_graph(data) {
  var nodes = [];
  var edges = [];
  data.forEach(function(elem) {
    var dist = elem.distribution;
    nodes.push({data: {id: dist, label: dist}});
    elem.children.forEach(function(child) {
      edges.push({data: {source: dist, target: child}});
    });
  });
  return {nodes: nodes, edges: edges};
}

function create_graph(elements, graphtype) {
  var layout;
  if (graphtype === 'cose') {
    layout = {
      name: 'cose',
      randomize: true
    };
  } else if (graphtype === 'topdown') {
    layout = {
      name: 'breadthfirst',
      directed: true,
      spacingFactor: 1
    };
  } else if (graphtype === 'concentric') {
    layout = {
      name: 'breadthfirst',
      circle: true,
      directed: true,
      spacingFactor: 1
    };
  } else {
    layout = {
      name: graphtype
    };
  }
  var cy = cytoscape({
    container: document.getElementById('deps'),
    elements: elements,
    minZoom: 0.1,
    maxZoom: 2,
    style: [
      {
        selector: 'node',
        style: {
          label: 'data(label)',
          'background-color': '#eeeeee',
          width: 'label',
          shape: 'round-rectangle',
          'text-valign': 'center'
        }
      },
      {
        selector: 'edge',
        style: {
          'curve-style': 'straight',
          'target-arrow-shape': 'vee',
          'arrow-scale': 2
        },
      }
    ],
    layout: layout
  });
}

var params = new URLSearchParams(window.location.search.substring(1));
var dist = params.get('dist');
var graphtype = params.get('type');
var phase = params.get('phase');
var recommends = params.get('recommends');
var suggests = params.get('suggests');
var perl_version = params.get('perl_version');

var deps_url = new URL('/api/v1/deps', window.location.href);
deps_url.searchParams.set('dist', dist);
deps_url.searchParams.set('phase', 'runtime');
if (phase === 'build') {
  deps_url.searchParams.append('phase', 'configure');
  deps_url.searchParams.append('phase', 'build');
} else if (phase === 'test') {
  deps_url.searchParams.append('phase', 'configure');
  deps_url.searchParams.append('phase', 'build');
  deps_url.searchParams.append('phase', 'test');
} else if (phase === 'develop') {
  deps_url.searchParams.append('phase', 'configure');
  deps_url.searchParams.append('phase', 'build');
  deps_url.searchParams.append('phase', 'test');
  deps_url.searchParams.append('phase', 'develop');
}
deps_url.searchParams.set('relationship', 'requires');
if (recommends) { deps_url.searchParams.append('relationship', 'recommends'); }
if (suggests) { deps_url.searchParams.append('relationship', 'suggests'); }
if (perl_version !== null) {
  deps_url.searchParams.set('perl_version', perl_version);
}
fetch(deps_url).then(function(response) {
  if (response.ok) {
    return response.json();
  } else {
    throw new Error(response.status + ' ' + response.statusText);
  }
}).then(function(data) {
  if (graphtype === null || graphtype === '') {
    graphtype = data.every(function(elem) { return elem.children.length < 10 ? true : false }) ? 'topdown' : 'concentric';
  }
  var elements = populate_graph(data);
  create_graph(elements, graphtype);
}).catch(function(error) {
  console.log('Error retrieving dependencies', error);
});
