/*
 * Scriptographer for Glyphs
 *
 * Runs a Paper.js script on the layers of Glyphs, in a realm of its own with
 * Scriptographer's bundle (scriptographer.js, shared with VectorCraft), which
 * gives it `print()`, `console`, `Dialog`, `Palette` and the web's APIs. The
 * script gets a PaperScope, with one hosted project per Glyphs layer, see
 * Project#host. As
 * in VectorCraft, y points down in the scripts, the other way than in Glyphs,
 * so the same scripts behave the same in both. The plugin provides the
 * natives as `__glyphs`, in Glyphs' coordinates:
 *
 * - `getLayer()` returns the active layer as `{ key, paths }`, with paths as
 *   `{ key, closed, nodes, selection }`, nodes flat as `x, y, type,
 *   connection` and the indices of the selected ones, or `null` without one.
 * - `setSelection(layerKey, selection)` selects the nodes of the paths,
 *   `{ key: indices }`, and nothing else.
 * - `setPaths(layerKey, edits)` applies edits `{ key, nodes, closed }`, `{ key,
 *   remove: true }` and `{ nodes, closed }` for new paths, in one undo step,
 *   and returns the keys of the new paths in order.
 * - `setTimer(delay, repeat, callback)` and `clearTimer(id)`, which keep the
 *   script running while they're set.
 * - `bindView()`, which makes the canvas made last the overlay's, drawing
 *   into Glyphs' edit view.
 */

var Scriptographer = new function() {
    var natives = __glyphs,
        // GSNodeType and GSNodeConnection:
        LINE = 1,
        CURVE = 35,
        QCURVE = 36,
        OFFCURVE = 65,
        SMOOTH = 100,
        // The script's scope, made when it first runs code:
        scope = null,
        // The overlay's canvas context, drawing into the edit view:
        overlay = null,
        // The handlers the script exported, which the runtime calls:
        handlers = {},
        // The last snapshot of each layer, by its key:
        snapshots = {};

    // Conversion of nodes and segments

    // Flips y between Glyphs and the scripts, without returning -0:
    function flip(y) {
        return 0 - y;
    }

    // The segments of the nodes, with the selection of the selected ones'
    // points and handles:
    function getSegments(nodes, closed, selection) {
        var points = [];
        for (var i = 0, l = nodes.length; i < l; i += 4) {
            points.push({
                x: nodes[i],
                y: flip(nodes[i + 1]),
                type: nodes[i + 2],
                selected: !!selection && selection.indexOf(i / 4) >= 0
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
                    segment.handleOut, segment.selection];
        });
    }

    // Paper.js's segment selection: the point 1, the handles 2 and 4.
    function createSegment(point) {
        return {
            x: point.x,
            y: point.y,
            handleIn: [0, 0],
            handleOut: [0, 0],
            selection: point.selected ? 1 : 0
        };
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
        if (point.selected)
            segment.selection |= name === 'handleIn' ? 2 : 4;
    }

    // Returns the nodes of a path in Glyphs' coordinates of the layer, and
    // puts the indices of the selected ones into `selection`, when given:
    function getNodes(path, matrix, selection) {
        var segments = path.segments,
            closed = path.closed,
            count = segments.length,
            nodes = [];
        function add(point, type, connection) {
            if (selection && point.selected)
                selection.push(nodes.length / 4);
            point = matrix ? matrix._transformPoint(point) : point;
            nodes.push(point.x, flip(point.y), type, connection || 0);
        }
        function addTo(segment, from) {
            if (from.handleOut.isZero() && segment.handleIn.isZero()) {
                add(segment.point, LINE);
            } else {
                add(getHandle(from, from.handleOut), OFFCURVE);
                add(getHandle(segment, segment.handleIn), OFFCURVE);
                add(segment.point, CURVE, segment.isSmooth() ? SMOOTH : 0);
            }
        }
        // A handle's absolute position, with whether it's selected:
        function getHandle(segment, handle) {
            var point = segment.point.add(handle);
            point.selected = handle.selected;
            return point;
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
                selection: path.selection,
                signature: path.closed + ':' + path.nodes.join(',') + ':'
                        + path.selection.join(',')
            };
        });
        snapshots[data.key] = snapshot;
        return snapshot;
    }

    // The records of the host for the layer and its paths, of the snapshot
    // when they're its paths:
    function getRecords(keys, flags, snapshot) {
        return {
            keys: keys,
            types: keys.map(function() {
                return 0;
            }),
            typeNames: [flags.typeName],
            flags: keys.map(function(key) {
                // visible: 2, strokeScaling: 8, and the flags of invalidate();
                // paths with selected nodes are selected: 1.
                var path = snapshot && snapshot.paths[key];
                return 2 | 8 | (flags.value || 0)
                        | (path && path.selection.length ? 1 : 0);
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
                            { typeName: 'Path' }, snapshots[layerKey]);
            },

            getItem: function(key) {
                var path = key !== layerKey && getPath(key);
                return path
                        ? ['Path', {
                            segments: getSegments(path.nodes, path.closed,
                                    path.selection),
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

    // Binding the scope to the active layer

    function bind(snapshot) {
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
            // The paths selected in Glyphs load, so the project knows them as
            // selected:
            snapshot.keys.forEach(function(key) {
                if (snapshot.paths[key].selection.length)
                    project.getItemByKey(key);
            });
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
                    { typeName: 'Path', value: 16 }, snapshot));
        }
        if (signatures[''] !== snapshot.keys.join(',')) {
            project.invalidate(getRecords([snapshot.key],
                    { typeName: 'Layer', value: 32 }));
        }
        project.takeChanges();
        project._glyphsSignatures = getSignatures(snapshot);
    }

    // Writing the changes back

    function commit() {
        var projects = scope._glyphsProjects;
        for (var key in projects) {
            var project = projects[key];
            if (key && project.hasChanges())
                commitProject(project, +key);
            if (key)
                commitSelection(project, +key);
        }
    }

    // Selects in Glyphs what the script selected, when it changed: the nodes
    // of the selected segments' points and handles, or all of a path's when
    // only the path is selected.
    function commitSelection(project, layerKey) {
        var snapshot = snapshots[layerKey],
            layer = project.layers[0],
            selection = {},
            isChanged = false;
        project.selectedItems.forEach(function(item) {
            if (item instanceof paper.Path && item.parent === layer
                    && item.key != null) {
                var indices = [],
                    nodes = getNodes(item, getLayerMatrix(item, layer),
                        indices);
                if (!indices.length) {
                    for (var i = 0; i < nodes.length / 4; i++)
                        indices.push(i);
                }
                selection[item.key] = indices;
            }
        });
        snapshot.keys.forEach(function(key) {
            var indices = selection[key] || [];
            isChanged = isChanged
                    || indices.join() !== snapshot.paths[key].selection.join();
        });
        if (isChanged) {
            natives.setSelection(layerKey, selection);
            snapshot = takeSnapshot();
            if (snapshot && snapshot.key === layerKey)
                project._glyphsSignatures = getSignatures(snapshot);
        }
    }

    // The classes of items dropped so far, which are warned about once:
    var dropped = {};

    function warnDropped(item) {
        var name = item.className;
        if (!dropped[name]) {
            dropped[name] = true;
            console.warn('Glyphs only keeps paths: ' + name
                    + ' items are dropped.');
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
                // Glyphs only has paths: groups and compound paths become
                // theirs, and what holds none is dropped, with a warning.
                var paths = child.getItems({ class: paper.Path });
                paths.forEach(function(path) {
                    var nodes = getNodes(path, getLayerMatrix(path, layer));
                    if (nodes.length)
                        edits.push({ nodes: nodes, closed: path.closed });
                });
                if (!paths.length)
                    warnDropped(child);
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

    // Runs a callback of the script between binding and writing back, once
    // it has a scope: classic scripts, as workers run, have none.
    function invoke(callback) {
        try {
            if (scope)
                bind(takeSnapshot());
            return callback();
        } catch (e) {
            report(e);
        } finally {
            try {
                if (scope)
                    commit();
            } catch (e) {
                report(e);
            }
        }
    }

    function report(error) {
        console.error(error && error.stack
                ? error + '\n' + error.stack
                : '' + error);
    }

    // The timers of the script, which the runtime gives scripts, not the
    // bundle:

    function setTimer(callback, delay, repeat, args) {
        return natives.setTimer(+delay || 0, repeat, function() {
            invoke(function() {
                callback.apply(null, args);
            });
        });
    }

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
    };
    self.requestAnimationFrame = function(callback) {
        return setTimer(function() {
            callback(performance.now());
        }, 1000 / 60, false, []);
    };
    self.cancelAnimationFrame = self.clearTimeout;

    // The API for the plugin

    function dispatch(callback) {
        var view = scope && scope.project && scope.project.view;
        if (view)
            invoke(function() {
                callback(view);
            });
    }

    return {
        // Runs the script's code, or a line of the console, in its scope:
        execute: function(source, file) {
            if (!scope) {
                scope = new paper.PaperScope();
                scope._glyphsProjects = {};
            }
            invoke(function() {
                // Without a layer, scripts still get a project:
                if (!scope.project) {
                    scope._glyphsProjects[''] = new scope.Project(
                            new scope.Size(1, 1));
                }
                var exported = scope.PaperScript.execute(source, scope, {
                    url: file,
                    handlers: ['onStartup', 'onShutdown', 'onStop',
                            'onAppActivate', 'onAppDeactivate',
                            'onEditOptions']
                });
                // A script with top-level await exports once it's done:
                if (exported && typeof exported.then === 'function') {
                    exported.then(function(exported) {
                        Object.assign(handlers, exported);
                    }, report);
                } else {
                    Object.assign(handlers, exported);
                }
            });
        },

        // The global `script`, as VectorCraft's runtime sets it up: its file
        // and folder as LocalFiles, `keepAlive`, which it sets to keep
        // running when another script runs, and `preferences`, as it last
        // left them, in Paper.js JSON, so they come back as Colors, Points…
        setScript: function(file, directory, preferences) {
            self.script = {
                file: file ? new LocalFile(file) : null,
                directory: directory ? new LocalFile(directory) : null,
                keepAlive: false,
                preferences: preferences
                        ? paper.Base.importJSON(preferences) : {}
            };
        },

        getPreferences: function() {
            var script = self.script;
            return script && script.preferences
                    ? paper.Base.exportJSON(script.preferences) : null;
        },

        keepsAlive: function() {
            return !!(self.script && self.script.keepAlive === true);
        },

        // Calls the handler the script exported, if it has it:
        callHandler: function(name) {
            var handler = handlers[name];
            if (typeof handler === 'function') {
                invoke(function() {
                    handler();
                });
                return true;
            }
            return false;
        },

        // Calls a function of the bundle that the runtime calls the script
        // with, as `handlePaletteEvent()`, between binding and writing back:
        call: function(func, args) {
            return invoke(function() {
                return func.apply(null, args);
            });
        },

        // Whether the script keeps running for its tool or its animation; the
        // runtime adds its timers and palettes:
        isRunning: function() {
            return !!(scope && (scope.tool
                    || scope.view && scope.view.responds('frame')));
        },

        // Whether the script draws over the layer, with the draw handlers of
        // its items (Item#onDraw, Item#onDrawSelection):
        hasDrawHandlers: function() {
            var project = scope && scope.project;
            return !!(project && project.hasDrawHandlers
                    && project.hasDrawHandlers());
        },

        // Draws the handlers over the layer, with `matrix` from the script's
        // coordinates to the view's, without writing anything back:
        drawOverlay: function(matrix, pixelRatio) {
            if (!this.hasDrawHandlers())
                return;
            try {
                bind(takeSnapshot());
                if (!overlay) {
                    var canvas = new OffscreenCanvas(1, 1);
                    natives.bindView();
                    overlay = canvas.getContext('2d');
                }
                scope.project.draw(overlay, new paper.Matrix(matrix),
                        pixelRatio);
            } catch (e) {
                report(e);
            }
        },

        hasTool: function() {
            return !!(scope && scope.tool);
        },

        stop: function() {
            if (scope) {
                scope.remove();
                scope = null;
            }
        },

        // Handles the mouse events of the Script tool, in Glyphs' coordinates
        // of the layer:
        mouse: function(type, x, y, modifiers) {
            dispatch(function(view) {
                view.dispatchMouseEvent(type, [x, flip(y)],
                        { modifiers: modifiers });
            });
        },

        // Handles the key events of the Script tool, and returns whether its
        // script responds to them:
        key: function(type, key, character, modifiers) {
            var isHandled = !!(scope && scope.tool
                    && scope.tool.responds(type));
            if (isHandled) {
                dispatch(function(view) {
                    view.dispatchKeyEvent(type, key,
                            { character: character, modifiers: modifiers });
                });
            }
            return isHandled;
        },

        // For tests:
        _getSegments: getSegments,
        _getNodes: getNodes
    };
};
