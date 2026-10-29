/*
 * Scriptographer for Glyphs
 *
 * Runs Paper.js scripts on the layers of Glyphs. Each script gets its own
 * PaperScope, with one hosted project per Glyphs layer, see Project#host. As
 * in VectorCraft, y points down in the scripts, the other way than in Glyphs,
 * so the same scripts behave the same in both. The plugin provides the
 * natives as `__glyphs`, in Glyphs' coordinates:
 *
 * - `getLayer()` returns the active layer as `{ key, paths }`, with paths as
 *   `{ key, closed, nodes }` and nodes flat as `x, y, type, connection`, or
 *   `null` without one.
 * - `setPaths(layerKey, edits)` applies edits `{ key, nodes, closed }`, `{ key,
 *   remove: true }` and `{ nodes, closed }` for new paths, in one undo step,
 *   and returns the keys of the new paths in order.
 * - `print(string)`, `setTimer(delay, repeat, callback)`, `clearTimer(id)`.
 */

var Scriptographer = new function() {
    var natives = __glyphs,
        // GSNodeType and GSNodeConnection:
        LINE = 1,
        CURVE = 35,
        QCURVE = 36,
        OFFCURVE = 65,
        SMOOTH = 100,
        // The scopes of the running scripts by their file, and the one whose
        // tool receives the mouse events:
        scopesByFile = {},
        toolScope = null,
        timersByScope = {},
        // The last snapshot of each layer, by its key:
        snapshots = {};

    // Conversion of nodes and segments

    // Flips y between Glyphs and the scripts, without returning -0:
    function flip(y) {
        return 0 - y;
    }

    function getSegments(nodes, closed) {
        var points = [];
        for (var i = 0, l = nodes.length; i < l; i += 4) {
            points.push({
                x: nodes[i],
                y: flip(nodes[i + 1]),
                type: nodes[i + 2]
            });
        }
        // Closed paths start at their last on-curve node. TrueType contours
        // without any start at the implied point between their last and first
        // off-curve node:
        if (closed) {
            var start = -1;
            for (var i = points.length - 1; i >= 0 && start < 0; i--) {
                if (points[i].type !== OFFCURVE)
                    start = i;
            }
            if (start >= 0) {
                points = points.slice(start).concat(points.slice(0, start));
            } else if (points.length) {
                var first = points[0],
                    last = points[points.length - 1];
                points.unshift({
                    x: (first.x + last.x) / 2,
                    y: (first.y + last.y) / 2,
                    type: QCURVE
                });
            }
        }
        var segments = [],
            controls = [];
        points.forEach(function(point, index) {
            if (point.type === OFFCURVE) {
                controls.push(point);
            } else if (index === 0) {
                segments.push(createSegment(point));
            } else {
                addCurve(segments, controls, point, false);
                controls = [];
            }
        });
        if (closed && segments.length)
            addCurve(segments, controls, points[0], true);
        return segments.map(function(segment) {
            return [[segment.x, segment.y], segment.handleIn,
                    segment.handleOut];
        });
    }

    function createSegment(point) {
        return { x: point.x, y: point.y, handleIn: [0, 0], handleOut: [0, 0] };
    }

    // Adds the curve to the on-curve point `to` with its off-curve points, or
    // closes the path with it into the first segment:
    function addCurve(segments, controls, to, closing) {
        var from = segments[segments.length - 1],
            end = closing ? segments[0] : createSegment(to);
        if (controls.length === 2 && to.type !== QCURVE) {
            setHandle(from, 'handleOut', controls[0]);
            setHandle(end, 'handleIn', controls[1]);
        } else if (controls.length) {
            // Quadratic curves, with the points between their controls
            // implied, raised to cubic curves:
            for (var i = 0, l = controls.length; i < l; i++) {
                var control = controls[i],
                    next = controls[i + 1],
                    target = next
                        ? createSegment({
                            x: (control.x + next.x) / 2,
                            y: (control.y + next.y) / 2
                        })
                        : end;
                setHandle(from, 'handleOut', control, 2 / 3);
                setHandle(target, 'handleIn', control, 2 / 3);
                if (next) {
                    segments.push(target);
                    from = target;
                }
            }
        }
        if (!closing)
            segments.push(end);
    }

    function setHandle(segment, name, point, factor) {
        factor = factor || 1;
        segment[name] = [
            (point.x - segment.x) * factor,
            (point.y - segment.y) * factor
        ];
    }

    // Returns the nodes of a path in Glyphs' coordinates of the layer:
    function getNodes(path, matrix) {
        var segments = path.segments,
            closed = path.closed,
            count = segments.length,
            nodes = [];
        function add(point, type, connection) {
            point = matrix ? matrix._transformPoint(point) : point;
            nodes.push(point.x, flip(point.y), type, connection || 0);
        }
        function addTo(segment, from) {
            if (from.handleOut.isZero() && segment.handleIn.isZero()) {
                add(segment.point, LINE);
            } else {
                add(from.point.add(from.handleOut), OFFCURVE);
                add(segment.point.add(segment.handleIn), OFFCURVE);
                add(segment.point, CURVE, segment.isSmooth() ? SMOOTH : 0);
            }
        }
        if (closed) {
            // Closed paths end with their first segment, see getSegments():
            for (var i = 1; i <= count; i++)
                addTo(segments[i % count], segments[i - 1]);
        } else if (count) {
            add(segments[0].point, LINE);
            for (var i = 1; i < count; i++)
                addTo(segments[i], segments[i - 1]);
        }
        return nodes;
    }

    // The matrix from an item's coordinates to its layer's, or null:
    function getLayerMatrix(item, layer) {
        var matrix = null;
        for (var parent = item; parent && parent !== layer;
                parent = parent.parent) {
            if (!parent.matrix.isIdentity()) {
                matrix = matrix
                        ? parent.matrix.appended(matrix)
                        : parent.matrix.clone();
            }
        }
        return matrix;
    }

    // Snapshots and the host

    function takeSnapshot() {
        var data = natives.getLayer();
        if (!data)
            return null;
        var snapshot = {
                key: data.key,
                keys: [],
                paths: {}
            };
        data.paths.forEach(function(path) {
            snapshot.keys.push(path.key);
            snapshot.paths[path.key] = {
                closed: path.closed,
                nodes: path.nodes,
                signature: path.closed + ':' + path.nodes.join(',')
            };
        });
        snapshots[data.key] = snapshot;
        return snapshot;
    }

    // The records of the host for the layer and its paths:
    function getRecords(keys, flags) {
        return {
            keys: keys,
            types: keys.map(function() {
                return 0;
            }),
            typeNames: [flags.typeName],
            flags: keys.map(function() {
                // visible: 2, strokeScaling: 8, and the flags of invalidate():
                return 2 | 8 | (flags.value || 0);
            })
        };
    }

    function createHost(layerKey) {
        function getPath(key) {
            return snapshots[layerKey].paths[key];
        }
        return {
            getChildren: function(key) {
                return key == null
                        ? getRecords([layerKey], { typeName: 'Layer' })
                        : getRecords(snapshots[layerKey].keys,
                            { typeName: 'Path' });
            },

            getItem: function(key) {
                var path = key !== layerKey && getPath(key);
                return path
                        ? ['Path', {
                            segments: getSegments(path.nodes, path.closed),
                            closed: path.closed
                        }]
                        : ['Layer', {}];
            },

            getBounds: function(key) {
                var bounds = key === layerKey
                        ? getLayerBounds()
                        : getPathBounds(getPath(key));
                return bounds && [
                    bounds.x, bounds.y, bounds.width, bounds.height,
                    bounds.x, bounds.y, bounds.width, bounds.height,
                    bounds.x, bounds.y, bounds.width, bounds.height
                ];
            },

            getAncestorKeys: function(key) {
                return key === layerKey ? [] : [layerKey];
            }
        };

        function getPathBounds(path) {
            return path && !path.nodes.length
                    ? null
                    : path && new paper.Path({
                        segments: getSegments(path.nodes, path.closed),
                        closed: path.closed,
                        insert: false
                    }).bounds;
        }

        function getLayerBounds() {
            var bounds = null;
            snapshots[layerKey].keys.forEach(function(key) {
                var rect = getPathBounds(getPath(key));
                if (rect)
                    bounds = bounds ? bounds.unite(rect) : rect;
            });
            return bounds;
        }
    }

    // Binding the scopes to the active layer

    function bind(scope, snapshot) {
        scope.activate();
        if (snapshot) {
            var projects = scope._glyphsProjects,
                project = projects[snapshot.key];
            if (project) {
                update(project, snapshot);
            } else {
                project = projects[snapshot.key] =
                        new scope.Project(new scope.Size(1, 1));
                project.trackChanges = true;
                project.host = createHost(snapshot.key);
                project._glyphsSignatures = getSignatures(snapshot);
            }
            project.activate();
        }
    }

    function getSignatures(snapshot) {
        var signatures = { '': snapshot.keys.join(',') };
        snapshot.keys.forEach(function(key) {
            signatures[key] = snapshot.paths[key].signature;
        });
        return signatures;
    }

    // Updates the items of the paths that changed in Glyphs since the project
    // saw them last:
    function update(project, snapshot) {
        var signatures = project._glyphsSignatures,
            changed = snapshot.keys.filter(function(key) {
                var signature = signatures[key];
                return signature !== undefined
                        && signature !== snapshot.paths[key].signature;
            });
        if (changed.length) {
            project.invalidate(getRecords(changed,
                    { typeName: 'Path', value: 16 }));
        }
        if (signatures[''] !== snapshot.keys.join(',')) {
            project.invalidate(getRecords([snapshot.key],
                    { typeName: 'Layer', value: 32 }));
        }
        project.takeChanges();
        project._glyphsSignatures = getSignatures(snapshot);
    }

    function bindAll() {
        var snapshot = takeSnapshot();
        for (var file in scopesByFile)
            bind(scopesByFile[file], snapshot);
        return snapshot;
    }

    // Writing the changes back

    function commit(scope) {
        var projects = scope._glyphsProjects;
        for (var key in projects) {
            var project = projects[key];
            if (key && project.hasChanges())
                commitProject(project, +key);
        }
    }

    function commitProject(project, layerKey) {
        var layer = project.layers[0],
            changes = project.takeChanges(),
            dirty = [],
            edits = [],
            added = [],
            isFlattened = false;
        changes.forEach(function(change) {
            var item = change.item;
            if (item && item !== layer) {
                // Paths of the layer that the script removed or moved away:
                if (item.key != null && (!item.isInserted()
                        || item.parent !== layer)) {
                    edits.push({ key: item.key, remove: true });
                }
                // The children of the layer that changed:
                var child = item;
                while (child && child.parent && child.parent !== layer)
                    child = child.parent;
                if (child && child.parent === layer
                        && dirty.indexOf(child) < 0) {
                    dirty.push(child);
                }
            }
        });
        dirty.forEach(function(child) {
            if (child instanceof paper.Path) {
                var edit = {
                    nodes: getNodes(child, getLayerMatrix(child, layer)),
                    closed: child.closed
                };
                if (child.key != null) {
                    edit.key = child.key;
                    edits.push(edit);
                } else if (edit.nodes.length) {
                    edits.push(edit);
                    added.push(child);
                }
            } else {
                // Glyphs only has paths: other items become their paths.
                child.getItems({ class: paper.Path }).forEach(function(path) {
                    var nodes = getNodes(path, getLayerMatrix(path, layer));
                    if (nodes.length)
                        edits.push({ nodes: nodes, closed: path.closed });
                });
                isFlattened = true;
            }
        });
        if (edits.length) {
            var keys = natives.setPaths(layerKey, edits);
            added.forEach(function(path, index) {
                path.key = keys[index];
            });
            var snapshot = takeSnapshot();
            if (isFlattened && snapshot && snapshot.key === layerKey) {
                project.invalidate(getRecords([layerKey],
                        { typeName: 'Layer', value: 32 }));
            }
            project.takeChanges();
            if (snapshot && snapshot.key === layerKey)
                project._glyphsSignatures = getSignatures(snapshot);
        }
    }

    function commitAll() {
        for (var file in scopesByFile)
            commit(scopesByFile[file]);
    }

    // Runs a callback of the scripts between binding and writing back:
    function invoke(callback) {
        try {
            bindAll();
            return callback();
        } catch (e) {
            report(e);
        } finally {
            try {
                commitAll();
            } catch (e) {
                report(e);
            }
        }
    }

    function report(error) {
        natives.print(error && error.stack
                ? error + '\n' + error.stack
                : '' + error);
    }

    // The globals of the scripts

    function format(args) {
        return Array.prototype.map.call(args, function(arg) {
            return typeof arg === 'string' ? arg : formatValue(arg);
        }).join(' ');
    }

    function formatValue(value) {
        if (value && typeof value === 'object' && !Array.isArray(value)
                && value.toString !== Object.prototype.toString) {
            return value.toString();
        }
        try {
            return JSON.stringify(value);
        } catch (e) {
            return '' + value;
        }
    }

    function setTimer(callback, delay, repeat, args) {
        var scope = paper,
            id = natives.setTimer(+delay || 0, repeat, function() {
                if (!repeat)
                    removeTimer(scope, id);
                invoke(function() {
                    callback.apply(null, args);
                });
            }),
            timers = timersByScope[scope._id] || (timersByScope[scope._id] = []);
        timers.push(id);
        return id;
    }

    function removeTimer(scope, id) {
        var timers = timersByScope[scope._id],
            index = timers ? timers.indexOf(id) : -1;
        if (index >= 0)
            timers.splice(index, 1);
    }

    self.print = function() {
        natives.print(format(arguments));
    };
    self.console = {
        log: self.print,
        info: self.print,
        warn: self.print,
        error: self.print,
        debug: self.print
    };
    self.setTimeout = function(callback, delay) {
        return setTimer(callback, delay, false,
                Array.prototype.slice.call(arguments, 2));
    };
    self.setInterval = function(callback, delay) {
        return setTimer(callback, delay, true,
                Array.prototype.slice.call(arguments, 2));
    };
    self.clearTimeout = self.clearInterval = function(id) {
        natives.clearTimer(id);
        for (var key in timersByScope) {
            var index = timersByScope[key].indexOf(id);
            if (index >= 0)
                timersByScope[key].splice(index, 1);
        }
    };

    // The API for the plugin

    function stop(file) {
        var scope = scopesByFile[file];
        if (scope) {
            (timersByScope[scope._id] || []).forEach(natives.clearTimer);
            delete timersByScope[scope._id];
            delete scopesByFile[file];
            if (toolScope === scope)
                toolScope = null;
            scope.remove();
        }
    }

    return {
        // Runs a script, stopping its previous run first. Returns whether it
        // keeps running: with a tool, timers or animation.
        run: function(source, file) {
            stop(file);
            var scope = new paper.PaperScope();
            scope._glyphsProjects = {};
            scopesByFile[file] = scope;
            invoke(function() {
                // Without a layer, scripts still get a project:
                if (!scope.project) {
                    scope._glyphsProjects[''] = new scope.Project(
                            new scope.Size(1, 1));
                }
                scope.PaperScript.execute(source, scope, { url: file });
                if (scope.tool)
                    toolScope = scope;
            });
            var isRunning = !!(scope.tool || (timersByScope[scope._id] || [])
                    .length || scope.view && scope.view.responds('frame'));
            if (!isRunning)
                stop(file);
            return isRunning;
        },

        stop: stop,

        isRunning: function(file) {
            return !!scopesByFile[file];
        },

        getToolFile: function() {
            for (var file in scopesByFile) {
                if (scopesByFile[file] === toolScope)
                    return file;
            }
            return null;
        },

        // Handles the mouse events of the Script tool, in Glyphs' coordinates
        // of the layer:
        mouse: function(type, x, y, modifiers) {
            var scope = toolScope;
            if (scope) {
                invoke(function() {
                    scope.activate();
                    var view = scope.project && scope.project.view;
                    if (view) {
                        view.dispatchMouseEvent(type, [x, flip(y)],
                                { modifiers: modifiers });
                    }
                });
            }
        },

        // Handles the key events of the Script tool, and returns whether its
        // script responds to them:
        key: function(type, key, character, modifiers) {
            var scope = toolScope,
                isHandled = !!(scope && scope.tool.responds(type));
            if (isHandled) {
                invoke(function() {
                    scope.activate();
                    var view = scope.project && scope.project.view;
                    if (view) {
                        view.dispatchKeyEvent(type, key,
                                { character: character, modifiers: modifiers });
                    }
                });
            }
            return isHandled;
        },

        // Evaluates code of the console in the scope of the tool's script, or
        // a scope of its own:
        evaluate: function(code) {
            var scope = toolScope;
            return invoke(function() {
                if (scope)
                    scope.activate();
                var result = (0, eval)(code);
                if (result !== undefined)
                    natives.print(formatValue(result));
                return result;
            });
        },

        // For tests:
        _getSegments: getSegments,
        _getNodes: getNodes
    };
};
