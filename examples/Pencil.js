// Draws a path along the mouse, smoothed when you let go.

tool.minDistance = 10

var path

function onMouseDown(event) {
    path = new Path()
    path.add(event.point)
}

function onMouseDrag(event) {
    path.add(event.point)
}

function onMouseUp(event) {
    path.simplify(5)
}
