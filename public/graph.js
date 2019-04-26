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
      nodeDimensionsIncludeLabels: true,
      randomize: true
    };
  } else {
    layout = {
      name: 'breadthfirst',
      circle: true,
      directed: true,
      spacingFactor: 1
    }
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
if (graphtype === null || graphtype === '') { graphtype = 'breadthfirst'; }

var deps_url = new URL('/api/v1/deps', window.location.href);
deps_url.searchParams.set('dist', dist);
deps_url.searchParams.set('phase', 'runtime');
deps_url.searchParams.set('relationship', 'requires');
fetch(deps_url).then(function(response) {
  if (response.ok) {
    return response.json();
  } else {
    throw new Error(response.status + ' ' + response.statusText);
  }
}).then(function(data) {
  var elements = populate_graph(data);
  create_graph(elements, graphtype);
}).catch(function(error) {
  console.log('Error retrieving dependencies', error);
});
