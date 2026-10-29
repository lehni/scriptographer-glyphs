// Draws stars from a palette, and asks for their name.

var values = {
    points: 5,
    radius: 200,
    ratio: 0.5
}

new Palette('Stars', {
    points: { type: 'number', label: 'Points', min: 3, max: 50, steppers: true },
    radius: { type: 'number', label: 'Radius', units: 'point', min: 1 },
    ratio: { type: 'slider', label: 'Ratio', range: [0.1, 1] },
    ruler: { type: 'ruler' },
    draw: {
        type: 'button', value: 'Draw',
        onClick: function() {
            new Path.Star({
                center: [300, -300],
                points: values.points,
                radius1: values.radius,
                radius2: values.radius * values.ratio
            })
        }
    },
    rename: {
        type: 'menu-entry', label: 'Name…',
        onSelect: function() {
            var answer = Dialog.prompt('Name', {
                name: { type: 'string', label: 'Name', value: 'Star' }
            })
            if (answer)
                print('Named ' + answer.name)
        }
    }
}, values)
