// Drags out circles from where you press.

var circle

function onMouseDrag(event) {
    if (circle)
        circle.remove()
    circle = new Path.Circle({
        center: event.downPoint,
        radius: event.downPoint.getDistance(event.point)
    })
}

function onMouseUp(event) {
    circle = null
}
