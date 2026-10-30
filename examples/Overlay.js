// Draws over the glyph without changing it: each path's start and the
// numbers of its points, and a crosshair where the mouse is, at the same
// size whatever the zoom.

var mouse

function onMouseMove(event) {
    mouse = event.point
}

project.activeLayer.onDraw = function(event) {
    var ctx = event.context,
        // One pixel of the view, in the glyph's units:
        pixel = 1 / event.pixelRatio
    ctx.font = 11 * pixel + 'px sans-serif'
    ctx.fillStyle = '#e0368b'
    this.children.forEach(function(path) {
        path.segments.forEach(function(segment, index) {
            var point = segment.point
            if (index === 0) {
                ctx.beginPath()
                ctx.arc(point.x, point.y, 5 * pixel, 0, 2 * Math.PI)
                ctx.fill()
            }
            ctx.fillText(index, point.x + 6 * pixel, point.y - 6 * pixel)
        })
    })
    if (mouse) {
        ctx.strokeStyle = '#2f7fe0'
        ctx.lineWidth = pixel
        ctx.beginPath()
        ctx.moveTo(mouse.x - 20 * pixel, mouse.y)
        ctx.lineTo(mouse.x + 20 * pixel, mouse.y)
        ctx.moveTo(mouse.x, mouse.y - 20 * pixel)
        ctx.lineTo(mouse.x, mouse.y + 20 * pixel)
        ctx.stroke()
    }
}
