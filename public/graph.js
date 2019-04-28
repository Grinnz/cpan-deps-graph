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

function create_graph(elements, graphstyle, root) {
  var layout;
  if (graphstyle === 'cose') {
    layout = {
      name: 'cose',
      randomize: true
    };
  } else if (graphstyle === 'topdown') {
    layout = {
      name: 'breadthfirst',
      directed: true,
      spacingFactor: 1,
      roots: '#' + root
    };
  } else if (graphstyle === 'concentric') {
    layout = {
      name: 'breadthfirst',
      circle: true,
      directed: true,
      spacingFactor: 1,
      roots: '#' + root
    };
  } else if (graphstyle === 'circle') {
    layout = {
      name: 'circle',
      spacingFactor: 0.5
    };
  } else {
    layout = {
      name: graphstyle
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
          width: 1.5,
          'curve-style': 'straight',
          'target-arrow-shape': 'vee',
          'arrow-scale': 1.5
        },
      }
    ],
    layout: layout
  });
  cy.on('tap', 'node', function(event) {
    var distname = event.target.data('label');
    document.getElementById('form-dist-name').setAttribute('value', distname);
  });
}

function retrieve_graph() {
  var params = new URLSearchParams(window.location.search.substring(1));
  var dist = params.get('dist');
  if (dist === null || dist === '') { return null; }
  var graphstyle = params.get('style');
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
  } else if (phase === 'configure') {
    deps_url.searchParams.set('phase', 'configure');
  }
  deps_url.searchParams.set('relationship', 'requires');
  if (recommends) { deps_url.searchParams.append('relationship', 'recommends'); }
  if (suggests) { deps_url.searchParams.append('relationship', 'suggests'); }
  if (perl_version !== null && perl_version !== '') {
    deps_url.searchParams.set('perl_version', perl_version);
  }
  fetch(deps_url).then(function(response) {
    if (response.ok) {
      return response.json();
    } else {
      throw new Error(response.status + ' ' + response.statusText);
    }
  }).then(function(data) {
    if (graphstyle === null || graphstyle === 'auto') {
      graphstyle = data.every(function(elem) { return elem.children.length <= 10 ? true : false }) ? 'topdown' : 'concentric';
    }
    var elements = populate_graph(data);
    create_graph(elements, graphstyle, dist);
  }).catch(function(error) {
    console.log('Error retrieving dependencies', error);
  });
}

retrieve_graph();
