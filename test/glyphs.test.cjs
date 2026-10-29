// Runs js/glyphs.js against a layer held in plain arrays, the way the plugin
// runs it in JavaScriptCore: without a DOM, with the natives as __glyphs.
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
      paths: layer.paths.map(p => ({ ...p, nodes: [...p.nodes] }))
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
    print: line => output.push(line),
    setTimer: () => 0,
    clearTimer() {}
  }
  const context = vm.createContext({ __glyphs: natives })
  vm.runInContext('var self = globalThis; var navigator = { userAgent: "Scriptographer" };', context)
  for (const file of ['vendor/paper-hosted.js', 'js/glyphs.js']) {
    vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context, { filename: file })
  }
  return { layer, output, Scriptographer: context.Scriptographer }
}

// Values from the VM's realm, as plain values of this one:
function plain(value) {
  return JSON.parse(JSON.stringify(value))
}

function round(nodes) {
  return plain(nodes).map(value => Math.round(value * 1000) / 1000)
}

test('closed paths start at their last node', () => {
  const { Scriptographer } = createGlyphs([])
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
  const { Scriptographer } = createGlyphs([])
  const nodes = [0, 0, LINE, 0, 30, 0, OFF, 0, 60, 30, OFF, 0, 60, 60, QCURVE, 0]
  const segments = plain(Scriptographer._getSegments(nodes, false))
  // The implied point between the two off-curve points becomes a segment:
  assert.deepStrictEqual(segments.map(s => s[0]), [[0, 0], [45, -15], [60, -60]])
  assert.deepStrictEqual(segments[0][2], [20, 0])
  assert.deepStrictEqual(segments[1][1], [-10, 10])
})

test('a tool script draws a new path into the layer', () => {
  const { layer, output, Scriptographer } = createGlyphs([])
  const isRunning = Scriptographer.run(`
    var path
    function onMouseDown(event) {
      path = new Path()
      path.add(event.point)
    }
    function onMouseDrag(event) {
      path.add(event.point)
    }
  `, 'draw.js')
  assert.ok(isRunning)
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
  const { layer, output, Scriptographer } = createGlyphs([{
    key: 2,
    closed: true,
    nodes: [100, 0, LINE, 0, 100, 100, LINE, 0, 0, 0, LINE, 0]
  }])
  Scriptographer.run('project.activeLayer.firstChild.translate(10, 20)', 'move.js')
  assert.deepStrictEqual(output, [])
  assert.strictEqual(layer.paths.length, 1)
  assert.strictEqual(layer.paths[0].key, 2)
  assert.deepStrictEqual(round(layer.paths[0].nodes),
      [110, -20, LINE, 0, 110, 80, LINE, 0, 10, -20, LINE, 0])
})

test('a running tool sees the changes made in Glyphs meanwhile', () => {
  const { layer, output, Scriptographer } = createGlyphs([{
    key: 2,
    closed: false,
    nodes: [0, 0, LINE, 0, 10, 0, LINE, 0]
  }])
  Scriptographer.run(`
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
  const { layer, output, Scriptographer } = createGlyphs([
    { key: 2, closed: false, nodes: [0, 0, LINE, 0, 10, 0, LINE, 0] },
    { key: 3, closed: false, nodes: [0, 0, LINE, 0, 20, 0, LINE, 0] }
  ])
  Scriptographer.run('project.activeLayer.firstChild.remove()', 'remove.js')
  assert.deepStrictEqual(output, [])
  assert.deepStrictEqual(layer.paths.map(p => p.key), [3])
})

test('errors are printed with their line', () => {
  const { output, Scriptographer } = createGlyphs([])
  Scriptographer.run('undefinedFunction()', 'error.js')
  assert.match(output[0], /undefinedFunction/)
})

test('closed curved paths are written back in the order of their nodes', () => {
  const nodes = [
    100, 0, OFF, 0, 200, 100, OFF, 0, 200, 200, CURVE, 100,
    0, 200, LINE, 0, 0, 0, LINE, 0
  ]
  const { layer, output, Scriptographer } = createGlyphs([{ key: 2, closed: true, nodes }])
  Scriptographer.run(`
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
  const { layer, output, Scriptographer } = createGlyphs([])
  Scriptographer.run(`
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
  const { output, Scriptographer } = createGlyphs([{
    key: 2,
    closed: true,
    nodes: [0, 0, LINE, 0, 100, 0, LINE, 0, 100, 100, LINE, 0, 0, 100, LINE, 0]
  }])
  Scriptographer.run(`
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
