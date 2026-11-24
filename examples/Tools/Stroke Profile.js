// Draws strokes along skeleton paths with pens that change their width, aspect
// and angle along the way, as Paper.js's stroke profiles, and writes their
// outlines next to them. Each skeleton keeps its profile in its data, and its
// outline the skeleton's id, so the tool picks up where it left off.
//
// Draw a skeleton in the empty space, or click one to edit it. Drag out from
// the stroke to add a stop. Drag the round handle of a stop to change its
// width and angle, with Shift only its width, the square one to change its
// aspect, and the stop itself to move it along the path. Alt-drag copies a
// stop, Delete removes the selected one. The skeleton's points and handles
// drag too, and the stops stay between the same points.

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

// The skeleton that the tool edits, its stop that's selected, the stop under
// the mouse that dragging out would add, and the view's points per unit of
// the glyph, as the overlay last drew them:
var skeleton = null;
var selected = null;
var hover = null;
var zoom = 1;
// What the mouse drags: { type, stop } of a stop, { type, segment } of the
// skeleton, or the new skeleton it draws:
var drag = null;
var drawing = null;

////////////////////////////////////////////////////////////////////////////////
// Skeletons and their outlines

// The profile that a skeleton keeps in its data: { id, width, stops }, with
// the stops' offsets along it.
function getProfile(item) {
	return item.data.strokeProfile;
}

function getSkeleton(id) {
	return project.activeLayer.children.filter(function(item) {
		return getProfile(item) && getProfile(item).id === id;
	})[0];
}

function getOutlines(id) {
	return project.activeLayer.children.filter(function(item) {
		return item.data.outlineOf === id;
	});
}

function getStops(path) {
	return (path.strokeProfile || []).map(function(stop) {
		var entry = { offset: stop.offset };
		['width', 'aspect', 'angle'].forEach(function(key) {
			if (stop[key] != null)
				entry[key] = stop[key];
		});
		if (!stop.smooth)
			entry.smooth = false;
		return entry;
	});
}

// Makes the path the skeleton that the tool edits, with its profile, which
// it loses when it's changed elsewhere:
function edit(path) {
	if (skeleton && skeleton !== path)
		skeleton.onDraw = null;
	skeleton = path;
	selected = null;
	if (path) {
		var stops = getProfile(path).stops;
		if (!(path.strokeProfile || []).length && stops.length)
			path.strokeProfile = stops;
		path.onDraw = drawStops;
	}
	updatePalette();
}

// Gives the path the profile chosen in the palette, as a skeleton that keeps
// its id once it has one:
function applyProfile(path) {
	var length = path.length;
	path.data.strokeProfile = {
		id: getProfile(path) ? getProfile(path).id
				: Math.random().toString(36).slice(2),
		width: values.width,
		stops: []
	};
	path.strokeProfile = profiles[values.profile].map(function(entry) {
		return {
			offset: entry.at * length,
			width: entry.width,
			aspect: entry.aspect,
			angle: entry.angle
		};
	});
	edit(path);
	update();
}

// Keeps the skeleton's profile in its data, and outlines it again, beneath
// it. The stroke that's outlined is a copy, so the skeleton keeps its own
// style:
function update() {
	var profile = getProfile(skeleton);
	profile.stops = getStops(skeleton);
	getOutlines(profile.id).forEach(function(item) {
		item.remove();
	});
	var stroke = skeleton.clone({ insert: false });
	stroke.set({
		data: {},
		strokeColor: 'black',
		strokeWidth: profile.width,
		strokeCap: 'round',
		strokeJoin: 'round'
	});
	var outline = stroke.outline({ insert: false });
	outline.set({ fillColor: 'black', strokeColor: null, selected: false });
	// Glyphs keeps the paths of compound paths, each with its data:
	outline.getItems({ class: Path }).concat(outline).forEach(function(item) {
		item.data = { outlineOf: profile.id };
	});
	outline.insertBelow(skeleton);
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

// Draws the skeleton's points and handles, which the app hides while the
// tool is active:
function drawSegments(ctx, matrix) {
	ctx.lineWidth = 1;
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
	matrix.inverted().applyToContext(ctx);
	drawSegments(ctx, matrix);
	if (values.showStops) {
		(skeleton.strokeProfile || []).forEach(function(stop) {
			drawMarker(ctx, matrix, getPen(stop.offset, getFullStop(stop)),
					stop, stop === selected);
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
			return { type: 'width', stop: stop };
		if (point.getDistance(pen.point + pen.minor) < tolerance)
			return { type: 'aspect', stop: stop };
		if (point.getDistance(pen.point) < tolerance)
			return { type: 'stop', stop: stop };
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

// The skeleton whose outline or path is at the point:
function hitSkeleton(point) {
	var items = project.activeLayer.children;
	for (var i = items.length - 1; i >= 0; i--) {
		var item = items[i],
			id = item.data.outlineOf;
		if (id && item.contains(point))
			return getSkeleton(id);
		if (getProfile(item)
				&& item.hitTest(point, { stroke: true, tolerance: 4 / zoom }))
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
	var location = skeleton && !hitStop(event.point)
			&& !hitSegments(event.point) && hitStroke(event.point);
	hover = location ? { offset: location.offset } : null;
}

function onMouseDown(event) {
	drag = null;
	hover = null;
	if (skeleton && !skeleton.isInserted())
		edit(null);
	if (skeleton)
		edit(skeleton);
	var hit = skeleton && hitStop(event.point);
	if (hit) {
		var stop = hit.stop;
		if (hit.type === 'stop' && event.modifiers.alt) {
			// Copy the stop and drag the copy, as in Illustrator:
			stop = stop.clone();
			skeleton.strokeProfile = skeleton.strokeProfile.concat(stop);
		}
		drag = { type: hit.type, stop: stop };
		selected = stop;
	} else if (skeleton && (hit = hitSegments(event.point))) {
		drag = { type: hit.type, segment: hit.segment };
	} else if (skeleton && (hit = hitStroke(event.point))) {
		// Dragging out from the stroke adds a stop there, with the width
		// that the profile has there, and changes it:
		var added = new StrokeProfileStop({
			offset: hit.offset,
			width: skeleton.getStrokeProfileAt(hit.offset).width
		});
		skeleton.strokeProfile = (skeleton.strokeProfile || []).concat(added);
		drag = { type: 'width', stop: added, keepAngle: true };
		selected = added;
		update();
	} else if ((hit = hitSkeleton(event.point))) {
		edit(hit);
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
	if (!drag)
		return;
	var stop = drag.stop,
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
	} else {
		var name = {
			'segment': 'point',
			'handle-in': 'handleIn',
			'handle-out': 'handleOut'
		}[drag.type];
		if (name)
			drag.segment[name] += event.delta;
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
	if ((event.key === 'backspace' || event.key === 'delete') && selected) {
		skeleton.strokeProfile = skeleton.strokeProfile.filter(function(stop) {
			return stop !== selected;
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
			if (skeleton)
				applyProfile(skeleton);
		}
	},
	width: {
		label: 'Width', type: 'number',
		steppers: true,
		min: 1,
		onChange: function(value) {
			if (skeleton) {
				getProfile(skeleton).width = value;
				update();
			}
		}
	},
	showStops: {
		label: 'Stops', type: 'boolean'
	}
};

new Palette('Stroke Profile', components, values);
