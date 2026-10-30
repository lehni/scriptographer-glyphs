// Runs js/glyphs.js against a layer held in plain arrays, the way the plugin
// runs it in JavaScriptCore: without a DOM, after Scriptographer's bundle, with
// the natives as __scriptographer and __glyphs.
const { test } = require('node:test')
const assert = require('node:assert')
const vm = require('node:vm')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')
const LINE = 1, CURVE = 35, QCURVE = 36, OFF = 65

function createGlyphs(paths) {
  const layer = { key: 1, paths }
  let nextKey = 100
  const output = []
  const natives = {
    getLayer: () => ({
      key: layer.key,
      paths: layer.paths.map(p => ({ selection: [], ...p, nodes: [...p.nodes] }))
    }),
    setPaths(layerKey, edits) {
      assert.strictEqual(layerKey, layer.key)
      const keys = []
      for (const edit of edits) {
        const index = layer.paths.findIndex(p => p.key === edit.key)
        if (edit.remove) {
          layer.paths.splice(index, 1)
        } else if (edit.key != null) {
          layer.paths[index] = { key: edit.key, closed: edit.closed, nodes: edit.nodes }
        } else {
          const key = nextKey++
          layer.paths.push({ key, closed: edit.closed, nodes: edit.nodes })
          keys.push(key)
        }
      }
      return keys
    },
    setSelection(layerKey, selection) {
      for (const path of layer.paths)
        path.selection = selection[path.key] ? [...selection[path.key]] : []
      layer.selections = (layer.selections || 0) + 1
    },
    setTimer: () => 0,
    clearTimer() {}
  }
  const scriptographer = {
    print: line => output.push(line),
    now: () => 0,
    canvas: { properties: [], release() {} }
  }
  const context = vm.createContext({ __glyphs: natives, __scriptographer: scriptographer })
  vm.runInContext('var self = globalThis; var navigator = { userAgent: "Scriptographer" };', context)
  for (const file of ['vendor/paper-hosted.js', 'vendor/scriptographer.js', 'js/glyphs.js']) {
    vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context, { filename: file })
  }
  const Scriptographer = context.Scriptographer
  // Runs scripts with the bundle's executeScript(), as the plugin does:
  const execute = (source, file) =>
    Scriptographer.execute(source, file, scriptographer.executeScript)
  return { layer, output, natives: scriptographer, Scriptographer, execute }
}

// Values from the VM's realm, as plain values of this one:
function plain(value) {
  return JSON.parse(JSON.stringify(value))
}

function round(nodes) {
  return plain(nodes).map(value => Math.round(value * 1000) / 1000)
}

test('closed paths start at their last node', () => {
  const { Scriptographer, execute } = createGlyphs([])
  // A closed path starts at its last node in Glyphs:
  const nodes = [
    100, 0, OFF, 0, 200, 100, OFF, 0, 200, 200, CURVE, 100,
    0, 200, LINE, 0, 0, 0, LINE, 0
  ]
  const segments = plain(Scriptographer._getSegments(nodes, true))
  assert.deepStrictEqual(segments.map(s => s[0]), [[0, 0], [200, -200], [0, -200]])
  assert.deepStrictEqual(segments[0][2], [100, 0])
  assert.deepStrictEqual(segments[1][1], [0, 100])
})

test('quadratic curves are raised to cubic curves, with implied points', () => {
  const { Scriptographer, execute } = createGlyphs([])
  const nodes = [0, 0, LINE, 0, 30, 0, OFF, 0, 60, 30, OFF, 0, 60, 60, QCURVE, 0]
  const segments = plain(Scriptographer._getSegments(nodes, false))
  // The implied point between the two off-curve points becomes a segment:
  assert.deepStrictEqual(segments.map(s => s[0]), [[0, 0], [45, -15], [60, -60]])
  assert.deepStrictEqual(segments[0][2], [20, 0])
  assert.deepStrictEqual(segments[1][1], [-10, 10])
})

test('a tool script draws a new path into the layer', () => {
  const { layer, output, Scriptographer, execute } = createGlyphs([])
  execute(`
    var path
    function onMouseDown(event) {
      path = new Path()
      path.add(event.point)
    }
    function onMouseDrag(event) {
      path.add(event.point)
    }
  `, 'draw.js')
  assert.ok(Scriptographer.isRunning())
  Scriptographer.mouse('mousedown', 0, 0, {})
  Scriptographer.mouse('mousemove', 100, 0, {})
  Scriptographer.mouse('mousemove', 100, 100, {})
  Scriptographer.mouse('mouseup', 100, 100, {})
  assert.deepStrictEqual(output, [])
  assert.strictEqual(layer.paths.length, 1)
  assert.deepStrictEqual(plain(layer.paths[0].nodes),
      [0, 0, LINE, 0, 100, 0, LINE, 0, 100, 100, LINE, 0])
})

test('a script changes the paths of the layer in place', () => {
  const { layer, output, Scriptographer, execute } = createGlyphs([{
    key: 2,
    closed: true,
    nodes: [100, 0, LINE, 0, 100, 100, LINE, 0, 0, 0, LINE, 0]
  }])
  execute('project.activeLayer.firstChild.translate(10, 20)', 'move.js')
  assert.deepStrictEqual(output, [])
  assert.strictEqual(layer.paths.length, 1)
  assert.strictEqual(layer.paths[0].key, 2)
  assert.deepStrictEqual(round(layer.paths[0].nodes),
      [110, -20, LINE, 0, 110, 80, LINE, 0, 10, -20, LINE, 0])
})

test('a running tool sees the changes made in Glyphs meanwhile', () => {
  const { layer, output, Scriptographer, execute } = createGlyphs([{
    key: 2,
    closed: false,
    nodes: [0, 0, LINE, 0, 10, 0, LINE, 0]
  }])
  execute(`
    function onMouseDown(event) {
      print(project.activeLayer.children.length, project.activeLayer.firstChild.lastSegment.point)
    }
  `, 'look.js')
  layer.paths[0].nodes = [0, 0, LINE, 0, 50, 0, LINE, 0]
  layer.paths.push({ key: 3, closed: false, nodes: [0, 0, LINE, 0] })
  Scriptographer.mouse('mousedown', 0, 0, {})
  assert.deepStrictEqual(output, ['2 { x: 50, y: 0 }'])
})

test('removed paths are removed from the layer', () => {
  const { layer, output, Scriptographer, execute } = createGlyphs([
    { key: 2, closed: false, nodes: [0, 0, LINE, 0, 10, 0, LINE, 0] },
    { key: 3, closed: false, nodes: [0, 0, LINE, 0, 20, 0, LINE, 0] }
  ])
  execute('project.activeLayer.firstChild.remove()', 'remove.js')
  assert.deepStrictEqual(output, [])
  assert.deepStrictEqual(layer.paths.map(p => p.key), [3])
})

test('errors are printed with their line', () => {
  const { output, Scriptographer, execute } = createGlyphs([])
  execute('undefinedFunction()', 'error.js')
  assert.match(output[0], /undefinedFunction/)
})

test('closed curved paths are written back in the order of their nodes', () => {
  const nodes = [
    100, 0, OFF, 0, 200, 100, OFF, 0, 200, 200, CURVE, 100,
    0, 200, LINE, 0, 0, 0, LINE, 0
  ]
  const { layer, output, Scriptographer, execute } = createGlyphs([{ key: 2, closed: true, nodes }])
  execute(`
    var path = project.activeLayer.firstChild
    path.translate(1, 0)
    path.translate(-1, 0)
  `, 'same.js')
  assert.deepStrictEqual(output, [])
  // Paper.js only sees smooth joins of two curves. The plugin keeps the
  // connections of nodes that it moves in place:
  assert.deepStrictEqual(round(layer.paths[0].nodes), nodes.map((value, i) =>
    i === 11 ? 0 : value))
})

test('new groups become their paths', () => {
  const { layer, output, Scriptographer, execute } = createGlyphs([])
  execute(`
    new Group([
      new Path.Line([0, 0], [10, 0]),
      new Path.Line([0, 10], [10, 10])
    ]).translate(5, 0)
  `, 'group.js')
  assert.deepStrictEqual(output, [])
  assert.deepStrictEqual(layer.paths.map(p => round(p.nodes)), [
    [5, 0, LINE, 0, 15, 0, LINE, 0],
    [5, -10, LINE, 0, 15, -10, LINE, 0]
  ])
})

test('y points down in scripts, as in VectorCraft', () => {
  // A counter-clockwise contour in Glyphs, as outer contours are:
  const { output, Scriptographer, execute } = createGlyphs([{
    key: 2,
    closed: true,
    nodes: [0, 0, LINE, 0, 100, 0, LINE, 0, 100, 100, LINE, 0, 0, 100, LINE, 0]
  }])
  execute(`
    function onMouseDown(event) {
      var path = project.activeLayer.firstChild
      print(event.point, path.bounds, path.clockwise)
    }
  `, 'look.js')
  Scriptographer.mouse('mousedown', 0, 100, {})
  // The script sees it the right way up, and counter-clockwise too:
  assert.deepStrictEqual(output, [
    '{ x: 0, y: -100 } { x: 0, y: -100, width: 100, height: 100 } false'
  ])
})

test('palettes change the layer through their handlers', () => {
  const { layer, output, natives, Scriptographer, execute } = createGlyphs([])
  execute(`
    new Palette('Lines', {
      length: {
        type: 'number', label: 'Length', value: 10,
        onChange: function(value) {
          new Path.Line([0, 0], [value, 0])
        }
      }
    })
  `, 'palette.js')
  assert.deepStrictEqual(output, [])
  assert.ok(natives.hasPalettes())
  assert.deepStrictEqual(plain(natives.takePalettes()), [{
    id: 1,
    title: 'Lines',
    components: [{ name: 'length', type: 'number', label: 'Length', value: 10 }]
  }])
  Scriptographer.call(natives.handlePaletteEvent, [1, 'change', 'length', 20])
  assert.deepStrictEqual(output, [])
  assert.deepStrictEqual(plain(layer.paths[0].nodes), [0, 0, LINE, 0, 20, 0, LINE, 0])
  // The panel shows the value already, so the palette doesn't change:
  assert.deepStrictEqual(plain(natives.takePalettes()), [])
  Scriptographer.call(natives.handlePaletteEvent, [1, 'close'])
  assert.ok(!natives.hasPalettes())
})

test('scripts see the nodes selected in Glyphs, and select their own', () => {
  const nodes = [0, 0, LINE, 0, 100, 0, LINE, 0, 100, 100, LINE, 0]
  const { layer, output, Scriptographer, execute } = createGlyphs([
    { key: 2, closed: false, nodes, selection: [1] },
    { key: 3, closed: false, nodes: [0, 0, LINE, 0, 10, 0, LINE, 0] }
  ])
  execute(`
    function onMouseDown(event) {
      var selected = project.selectedItems
      print(selected.length, selected[0].key, selected[0].segments.map(function(s) {
        return s.selected
      }))
    }
    function onMouseUp(event) {
      project.activeLayer.lastChild.lastSegment.selected = true
    }
  `, 'select.js')
  Scriptographer.mouse('mousedown', 0, 0, {})
  assert.deepStrictEqual(output, ['1 2 [false, true, false]'])
  // What the script doesn't change stays as Glyphs has it:
  assert.strictEqual(layer.selections, undefined)
  Scriptographer.mouse('mouseup', 0, 0, {})
  assert.deepStrictEqual(layer.paths.map(p => plain(p.selection)), [[1], [1]])
})

test('items without paths are dropped, with a warning', () => {
  const { layer, output, Scriptographer, execute } = createGlyphs([])
  execute(`
    new PointText([0, 0]).content = 'a'
    new PointText([0, 10]).content = 'b'
  `, 'text.js')
  assert.deepStrictEqual(layer.paths, [])
  assert.deepStrictEqual(output, ['Glyphs only keeps paths: PointText items are dropped.'])
})
