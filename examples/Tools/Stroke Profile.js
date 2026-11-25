// Draws strokes along skeleton paths with pens that change their width, aspect
// and angle along the way, as Paper.js's stroke profiles. Each skeleton keeps
// its profile in a live effect, Stroke Profile, which draws its outline
// beneath it, and draws it again whenever the skeleton changes, also with the
// app's own tools, while the script runs.
//
// Draw a skeleton in the empty space, or click one to edit it. Clicking any
// other path, as drawn with the app's own tools, gives it the profile chosen
// in the palette and makes it a skeleton. Drag out from the stroke to add a
// stop. Drag the round handle of a stop to change its width and angle, with
// Shift only its width, the square one to change its aspect, and the stop
// itself to move it along the path. Alt-drag copies a stop, Delete removes the
// selected one. The skeleton's points and handles drag too, and the stops stay
// between the same points.

////////////////////////////////////////////////////////////////////////////////
// Values

// The profiles, as stops at fractions of the path's length:
var profiles = {
	'Pressure': [
		{ at: 0, width: 0.2, aspect: 0.15, angle: -35 },
		{ at: 0.3, width: 1.4 },
		{ at: 0.7, width: 1.1 },
		{ at: 1, width: 0.2 }
	],
	'Broad nib': [{ at: 0, width: 1.3, aspect: 0.12, angle: -35 }],
	'Twist': [
		{ at: 0, width: 1.2, aspect: 0.15, angle: 0 },
		{ at: 1, angle: 360 }
	],
	'Swell': [
		{ at: 0, width: 0.2 },
		{ at: 0.5, width: 1.6 },
		{ at: 1, width: 0.2 }
	],
	'Taper': [{ at: 0, width: 1.4 }, { at: 1, width: 0.05 }],
	'Brush': [
		{ at: 0, width: 0 },
		{ at: 0.12, width: 1.2 },
		{ at: 0.7, width: 0.8 },
		{ at: 1, width: 0 }
	],
	'Uniform': []
};

var values = {
	profile: 'Pressure',
	width: 60,
	showStops: true
};

var colors = {
	marker: '#1060ff',
	ghost: 'rgba(16, 96, 255, 0.4)'
};

// The skeleton that the tool edits, the index of its stop that's selected,
// the stop under the mouse that dragging out would add, and the view's points
// per unit of the glyph, as the overlay last drew them. Stops and segments go
// by their indices, as the skeleton loads them again when the app changes it:
var skeleton = null;
var selected = null;
var hover = null;
var zoom = 1;
// What the mouse drags: { type, index } of a stop or a segment of the
// skeleton, or the new skeleton it draws:
var drag = null;
var drawing = null;

////////////////////////////////////////////////////////////////////////////////
// The effect

// The outline of the area that the pens of the profile sweep along the path:
new Effect({
	type: 'stroke-profile',
	label: 'Stroke Profile',
	parameters: {
		width: { label: 'Width', type: 'number', value: 60 },
		stops: { value: [] }
	},
	onApply: function(event) {
		var art = event.art;
		art.set({
			strokeColor: 'black',
			strokeWidth: this.width,
			strokeCap: 'round',
			strokeJoin: 'round',
			strokeProfile: this.stops
		});
		return art.outline({ insert: false });
	}
});

////////////////////////////////////////////////////////////////////////////////
// Skeletons

// The skeleton's use of the effect, with its width and its stops, or null:
function getProfile(item) {
	return item.effects.filter(function(effect) {
		return effect.type === 'stroke-profile';
	})[0] || null;
}

// The stops as the effect keeps them, by their index between the path's
// segments, so they follow when the app reshapes it:
function getStops(path) {
	return (path.strokeProfile || []).map(function(stop) {
		return stop.exportJSON({ asString: false });
	});
}

// The path's stroke profile shows the pens: the effect's stops, the one place
// that keeps them. The path loses its own when it loads again:
function loadStops(path) {
	var stops = getProfile(path).stops;
	if (!(path.strokeProfile || []).length && stops.length)
		path.strokeProfile = stops;
}

// The skeleton that the tool edits, letting go of it once the app removed it
// or its effect:
function getSkeleton() {
	if (skeleton && (!skeleton.isInserted() || !getProfile(skeleton)))
		edit(null);
	return skeleton;
}

// Makes the path the skeleton that the tool edits:
function edit(path) {
	if (skeleton && skeleton !== path)
		skeleton.onDraw = null;
	skeleton = path;
	selected = null;
	if (path) {
		loadStops(path);
		path.onDraw = drawStops;
	}
	updatePalette();
}

// Gives the path the profile chosen in the palette, as a skeleton:
function applyProfile(path) {
	var length = path.length;
	path.strokeProfile = profiles[values.profile].map(function(entry) {
		return {
			offset: entry.at * length,
			width: entry.width,
			aspect: entry.aspect,
			angle: entry.angle
		};
	});
	if (!getProfile(path))
		path.addEffect({ type: 'stroke-profile' });
	getProfile(path).width = values.width;
	edit(path);
	update();
}

// Keeps the stops in the effect, which draws the outline again:
function update() {
	getProfile(skeleton).stops = getStops(skeleton);
}

////////////////////////////////////////////////////////////////////////////////
// Pens

// The pen at the offset: its center, its half axes as vectors, and its
// values:
function getPen(offset, stop) {
	var loc = skeleton.getLocationAt(offset) || skeleton.getLocationAt(
			offset > 0 ? skeleton.length : 0),
		pen = stop || skeleton.getStrokeProfileAt(offset),
		radius = getProfile(skeleton).width * pen.width / 2;
	return {
		point: loc.point,
		major: new Point(radius, 0).rotate(pen.angle),
		minor: new Point(0, radius * pen.aspect).rotate(pen.angle),
		stop: pen
	};
}

// The stop with the values that it takes from the stops around it:
function getFullStop(stop) {
	var pen = skeleton.getStrokeProfileAt(stop.offset);
	['width', 'aspect', 'angle'].forEach(function(key) {
		if (stop[key] != null)
			pen[key] = stop[key];
	});
	return pen;
}

////////////////////////////////////////////////////////////////////////////////
// Drawing

// Draws a stop's pen in the view's points: its ellipse, its center to move
// it, a handle at the end of its width to change it and the angle, and one at
// the end of its height to change the aspect. The values that the stop takes
// from the stops around it are faded:
function drawMarker(ctx, matrix, pen, stop, isSelected) {
	var size = 9,
		center = matrix.transform(pen.point),
		major = matrix.transform(pen.point + pen.major) - center,
		minor = matrix.transform(pen.point + pen.minor) - center,
		angle = major.angle * Math.PI / 180;

	function setStyle(key) {
		var color = !stop || key && stop[key] == null ? colors.ghost
				: colors.marker;
		ctx.strokeStyle = color;
		ctx.fillStyle = isSelected && (!key || stop[key] != null)
				? color : 'white';
	}

	function drawSquare(point, size, angle) {
		ctx.save();
		ctx.translate(point.x, point.y);
		ctx.rotate(angle);
		ctx.beginPath();
		ctx.rect(-size / 2, -size / 2, size, size);
		ctx.fill();
		ctx.stroke();
		ctx.restore();
	}

	ctx.lineWidth = 1.5;
	setStyle('aspect');
	ctx.setLineDash([4, 3]);
	ctx.beginPath();
	ctx.ellipse(center.x, center.y, major.length, minor.length, angle,
			0, 2 * Math.PI);
	ctx.stroke();
	ctx.setLineDash([]);
	setStyle('angle');
	ctx.beginPath();
	ctx.moveTo(center.x - major.x, center.y - major.y);
	ctx.lineTo(center.x + major.x, center.y + major.y);
	ctx.stroke();
	setStyle(null);
	drawSquare(center, size, Math.PI / 4);
	setStyle('width');
	ctx.beginPath();
	ctx.arc(center.x + major.x, center.y + major.y, 4.5, 0, 2 * Math.PI);
	ctx.fill();
	ctx.stroke();
	setStyle('aspect');
	drawSquare(center + minor, size * 2 / 3, angle);
}

// Draws the skeleton's line, points and handles, which the app may hide while
// the tool is active, or draw the effect in their place:
function drawSegments(ctx, matrix) {
	ctx.lineWidth = 1;
	ctx.strokeStyle = '#222';
	ctx.beginPath();
	skeleton.curves.forEach(function(curve) {
		var point1 = matrix.transform(curve.point1),
			handle1 = matrix.transform(curve.point1 + curve.handle1),
			handle2 = matrix.transform(curve.point2 + curve.handle2),
			point2 = matrix.transform(curve.point2);
		if (!curve.index)
			ctx.moveTo(point1.x, point1.y);
		ctx.bezierCurveTo(handle1.x, handle1.y, handle2.x, handle2.y,
				point2.x, point2.y);
	});
	ctx.stroke();
	ctx.strokeStyle = ctx.fillStyle = '#222';
	skeleton.segments.forEach(function(segment) {
		var point = matrix.transform(segment.point);
		[segment.handleIn, segment.handleOut].forEach(function(handle) {
			if (!handle.isZero()) {
				var end = matrix.transform(segment.point + handle);
				ctx.beginPath();
				ctx.moveTo(point.x, point.y);
				ctx.lineTo(end.x, end.y);
				ctx.stroke();
				ctx.beginPath();
				ctx.arc(end.x, end.y, 2.5, 0, 2 * Math.PI);
				ctx.fill();
			}
		});
		ctx.fillRect(point.x - 3, point.y - 3, 6, 6);
	});
}

// The skeleton's draw handler: the context is in the skeleton's coordinates,
// and the markers draw in the view's points, with the matrix to them:
function drawStops(event) {
	var ctx = event.context,
		matrix = event.matrix;
	zoom = matrix.scaling.x;
	if (!getSkeleton())
		return;
	loadStops(skeleton);
	matrix.inverted().applyToContext(ctx);
	drawSegments(ctx, matrix);
	if (values.showStops) {
		(skeleton.strokeProfile || []).forEach(function(stop, index) {
			drawMarker(ctx, matrix, getPen(stop.offset, getFullStop(stop)),
					stop, index === selected);
		});
	}
	if (hover)
		drawMarker(ctx, matrix, getPen(hover.offset));
}

////////////////////////////////////////////////////////////////////////////////
// Hit testing

// The stop or the handle of a stop at the point:
function hitStop(point) {
	var tolerance = 8 / zoom,
		stops = values.showStops && skeleton.strokeProfile || [];
	for (var i = stops.length - 1; i >= 0; i--) {
		var stop = stops[i],
			pen = getPen(stop.offset, getFullStop(stop));
		if (point.getDistance(pen.point + pen.major) < tolerance)
			return { type: 'width', index: i };
		if (point.getDistance(pen.point + pen.minor) < tolerance)
			return { type: 'aspect', index: i };
		if (point.getDistance(pen.point) < tolerance)
			return { type: 'stop', index: i };
	}
	return null;
}

function hitSegments(point) {
	return skeleton.hitTest(point, {
		segments: true,
		handles: true,
		tolerance: 6 / zoom
	});
}

// The skeleton whose stroke is at the point, within half its pen's width
// where it's nearest, and the tolerance beyond, which covers what its effect
// draws, so it isn't taken for another path:
function hitSkeleton(point) {
	var items = project.activeLayer.children;
	for (var i = items.length - 1; i >= 0; i--) {
		var item = items[i],
			profile = getProfile(item);
		if (profile) {
			loadStops(item);
			var location = item.getNearestLocation(point),
				pen = item.getStrokeProfileAt(location.offset);
			if (location.point.getDistance(point)
					<= profile.width * pen.width / 2 + 4 / zoom)
				return item;
		}
	}
	return null;
}

// Any other path at the point, which can become a skeleton. Paths in the
// app may have no stroke to hit, so it's by their nearest point:
function hitPath(point) {
	var items = project.activeLayer.children;
	for (var i = items.length - 1; i >= 0; i--) {
		var item = items[i];
		if (item instanceof Path && !getProfile(item) && item.length
				&& item.getNearestPoint(point).getDistance(point) <= 4 / zoom)
			return item;
	}
	return null;
}

// The location on the skeleton within its stroke, where a new stop goes:
function hitStroke(point) {
	return values.showStops && hitSkeleton(point) === skeleton
			? skeleton.getNearestLocation(point)
			: null;
}

////////////////////////////////////////////////////////////////////////////////
// Mouse and keys

function onMouseMove(event) {
	if (getSkeleton())
		loadStops(skeleton);
	var location = skeleton && !hitStop(event.point)
			&& !hitSegments(event.point) && hitStroke(event.point);
	hover = location ? { offset: location.offset } : null;
}

function onMouseDown(event) {
	drag = null;
	hover = null;
	if (getSkeleton())
		edit(skeleton);
	var hit = skeleton && hitStop(event.point);
	if (hit) {
		var index = hit.index;
		if (hit.type === 'stop' && event.modifiers.alt) {
			// Copy the stop and drag the copy, as in Illustrator:
			var copy = skeleton.strokeProfile[index].clone();
			skeleton.strokeProfile = skeleton.strokeProfile.concat(copy);
			index = skeleton.strokeProfile.indexOf(copy);
		}
		drag = { type: hit.type, index: index };
		selected = index;
	} else if (skeleton && (hit = hitSegments(event.point))) {
		drag = { type: hit.type, index: hit.segment.index };
	} else if (skeleton && (hit = hitStroke(event.point))) {
		// Dragging out from the stroke adds a stop there, with the width
		// that the profile has there, and changes it:
		var added = new StrokeProfileStop({
			offset: hit.offset,
			width: skeleton.getStrokeProfileAt(hit.offset).width
		});
		skeleton.strokeProfile = (skeleton.strokeProfile || []).concat(added);
		selected = skeleton.strokeProfile.indexOf(added);
		drag = { type: 'width', index: selected, keepAngle: true };
		update();
	} else if ((hit = hitSkeleton(event.point))) {
		edit(hit);
	} else if ((hit = hitPath(event.point))) {
		applyProfile(hit);
	} else {
		edit(null);
		drawing = new Path({ segments: [event.point] });
	}
}

function onMouseDrag(event) {
	if (drawing) {
		drawing.add(event.point);
		return;
	}
	if (!drag || !getSkeleton())
		return;
	loadStops(skeleton);
	var stop = skeleton.strokeProfile && skeleton.strokeProfile[drag.index],
		width = getProfile(skeleton).width;
	if (drag.type === 'width') {
		var pen = getPen(stop.offset, getFullStop(stop)),
			vector = event.point - pen.point;
		if (drag.keepAngle || event.modifiers.shift) {
			// Only along the axis of the pen:
			vector = vector.project(pen.major);
		} else {
			// Turn on from the current angle by the change in the direction,
			// so that angles go on past 180° instead of wrapping around:
			var angle = pen.stop.angle;
			stop.angle = angle + ((vector.angle - angle) % 360 + 540) % 360
					- 180;
		}
		stop.width = Math.round(2 * vector.length / width * 100) / 100;
	} else if (drag.type === 'aspect') {
		var pen = getPen(stop.offset, getFullStop(stop)),
			height = (event.point - pen.point).project(pen.minor);
		stop.aspect = Math.round(height.length / pen.major.length * 100) / 100;
	} else if (drag.type === 'stop') {
		stop.offset = skeleton.getNearestLocation(event.point).offset;
		// Moving past another stop changes their order:
		drag.index = selected = skeleton.strokeProfile.indexOf(stop);
	} else {
		var name = {
			'segment': 'point',
			'handle-in': 'handleIn',
			'handle-out': 'handleOut'
		}[drag.type];
		if (name)
			skeleton.segments[drag.index][name] += event.delta;
	}
	update();
}

function onMouseUp(event) {
	drag = null;
	if (drawing) {
		if (drawing.segments.length > 2) {
			drawing.simplify(10);
			applyProfile(drawing);
		} else {
			drawing.remove();
		}
		drawing = null;
	}
}

function onKeyDown(event) {
	if ((event.key === 'backspace' || event.key === 'delete')
			&& selected != null && getSkeleton()) {
		loadStops(skeleton);
		skeleton.strokeProfile = skeleton.strokeProfile.filter(
				function(stop, index) {
			return index !== selected;
		});
		selected = null;
		update();
		return false;
	}
}

////////////////////////////////////////////////////////////////////////////////
// Interface

// The palette shows the width of the skeleton that the tool edits:
function updatePalette() {
	if (skeleton)
		values.width = getProfile(skeleton).width;
}

var components = {
	profile: {
		label: 'Profile',
		options: Object.keys(profiles),
		onChange: function() {
			if (getSkeleton())
				applyProfile(skeleton);
		}
	},
	width: {
		label: 'Width', type: 'number',
		steppers: true,
		min: 1,
		onChange: function(value) {
			if (getSkeleton())
				getProfile(skeleton).width = value;
		}
	},
	showStops: {
		label: 'Stops', type: 'boolean'
	}
};

new Palette('Stroke Profile', components, values);
