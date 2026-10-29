// Prints the paths of the current layer, with their number of segments and
// their length.

project.activeLayer.children.forEach(function(path, index) {
    print('Path ' + index + ': ' + path.segments.length + ' segments, length '
        + path.length.toFixed(1) + (path.clockwise ? ', clockwise' : ''))
})
