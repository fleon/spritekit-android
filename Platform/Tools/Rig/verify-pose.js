// Checks PlatformRigs' runtime (RigData, RigPose) against Spine's own
// runtimes, frame by frame.
//
//   node verify-pose.js --rigs <dir> [--spine-core <dir>] [--spine-c <dir>]
//     [--schedules <file.json>] [--only <substring>] [--out <dir>]
//     [--scale <s>] [--mix <seconds>] [--drift <x,y>] [--no-loops]
//
// --rigs: a folder of rigs, each Rig<Name>.json: a Spine 4.2 skeleton, or
//   places only (`atlas`) naming its skeleton (`rig`) in a deflated
//   Rig<rig>.skel beside it.
// 1. RigPose in its 4.2 mode against spine-core 4.2 (spine42-dump.mjs;
//    --spine-core: an installed @esotericsoftware/spine-core).
// 2. RigPose in its 3.6 mode against spine-c 3.6 (spine36-dump.c; --spine-c:
//    its sources), in float and in double precision, on the 4.2 JSON written
//    back as 3.6 (spine36-convert.js).
// Every rig's animations each play looped (unless --no-loops; with --mix, also crossfading from
// the one before, and with --drift, while the skeleton travels that far each
// frame, which its physics trails), plus the runs in --schedules: a JSON list
// of { id, rig, frames, actions: [{ frame, op: set|add|origin|clear, track,
// name, loop, delay, mix, timeScale, x, y }], dt?, dts?, mix?, drift?, scale? }.
// Each prints the largest difference per run: bone transforms (a b c d / x y),
// vertices, colours, attachments that differ, and listener events that differ.

const fs = require('fs')
const os = require('os')
const path = require('path')
const zlib = require('zlib')
const { execFileSync } = require('child_process')

const args = process.argv.slice(2)
const option = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : fallback
}
const rigsSource = option('--rigs')
if (!rigsSource) {
  console.error('usage: node verify-pose.js --rigs <dir> [--spine-core <dir>] [--spine-c <dir>] [--schedules <file>] [--only <s>] [--out <dir>]')
  process.exit(2)
}
const spineCore = option('--spine-core', process.env.SPINE_CORE)
const spineC = option('--spine-c', process.env.SPINE_C)
const outDir = option('--out', path.join(os.tmpdir(), 'rig-verify'))
const only = option('--only', '')
const scale = Number(option('--scale', '1'))
const mix = Number(option('--mix', '0'))
const drift = option('--drift', '').split(',').filter(Boolean).map(Number)
const schedules = option('--schedules')
const loops = !args.includes('--no-loops')
const sources = path.resolve(__dirname, '../../Sources/PlatformRigs')
fs.mkdirSync(outDir, { recursive: true })

// A step that never lands exactly on a key or loop boundary, where float32
// (spine-c) and double (RigPose) times round to opposite sides.
const FPS = 60
const DT = 1 / 60.02

// Every rig as one plain skeleton JSON, its places merged in.
const rigsDir = path.join(outDir, 'rigs')
fs.mkdirSync(rigsDir, { recursive: true })
const rigs = []
for (const file of fs.readdirSync(rigsSource).filter((f) => /^Rig.+\.json$/.test(f))) {
  const name = file.slice(3, -5)
  if (!name.includes(only)) continue
  let json = JSON.parse(fs.readFileSync(path.join(rigsSource, file), 'utf8'))
  if (!json.bones && json.rig) {
    const skel = path.join(rigsSource, `Rig${json.rig}.skel`)
    if (!fs.existsSync(skel)) continue
    json = { ...JSON.parse(zlib.inflateSync(fs.readFileSync(skel)).toString('utf8')), ...json }
  }
  if (!json.bones || !json.animations) continue
  fs.writeFileSync(path.join(rigsDir, file), JSON.stringify(json))
  rigs.push({ name, json })
}

function animationDuration (animation) {
  let duration = 0
  const walk = (o) => {
    if (Array.isArray(o)) {
      for (const k of o) if (k && typeof k === 'object' && !Array.isArray(k)) duration = Math.max(duration, k.time || 0)
      o.forEach(walk)
    } else if (o && typeof o === 'object') for (const k in o) walk(o[k])
  }
  walk(animation)
  return duration
}

function plan () {
  const runs = []
  for (const { name: rig, json } of loops ? rigs : []) {
    const names = Object.keys(json.animations)
    names.forEach((name, i) => {
      const duration = animationDuration(json.animations[name])
      const frames = Math.ceil(Math.max(duration + 2, 3) * FPS)
      const run = { id: `${rig}.${name}`, rig, scale, dt: DT, frames, vertexEvery: 5, actions: [{ frame: 0, op: 'set', track: 0, name, loop: true }] }
      if (drift.length === 2) run.drift = drift
      runs.push(run)
      // Crossfading in from the animation before it, a second in.
      if (mix > 0 && names.length > 1) {
        const from = names[(i + names.length - 1) % names.length]
        runs.push({ ...run, id: `${rig}.${from}>${name}`, mix, actions: [
          { frame: 0, op: 'set', track: 0, name: from, loop: true },
          { frame: FPS, op: 'set', track: 0, name, loop: true }
        ] })
      }
    })
  }
  if (schedules) {
    for (const run of JSON.parse(fs.readFileSync(schedules, 'utf8'))) {
      if (run.rig.includes(only)) runs.push({ scale, dt: DT, vertexEvery: 5, ...run })
    }
  }
  return { rigsDir, runs }
}

function readRun (file) {
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l))
  return { header: lines[0], frames: lines.slice(1, -1), events: lines[lines.length - 1].events }
}

// Compares two dumps by bone and slot name (3.6 and 4.2 JSON may order them differently).
function compare (a, b) {
  const result = { abcd: 0, xy: 0, vertices: 0, color: 0, attachments: 0, events: 0, worst: '' }
  const boneMap = a.header.bones.map((n) => b.header.bones.indexOf(n))
  const slotMap = a.header.slots.map((n) => b.header.slots.indexOf(n))
  const frames = Math.min(a.frames.length, b.frames.length)
  for (let f = 0; f < frames; f++) {
    const fa = a.frames[f], fb = b.frames[f]
    boneMap.forEach((j, i) => {
      if (j < 0) return
      for (let k = 0; k < 6; k++) {
        const d = Math.abs(fa.b[i * 6 + k] - fb.b[j * 6 + k])
        const key = k < 4 ? 'abcd' : 'xy'
        if (d > result[key]) {
          result[key] = d
          if (key === 'xy') result.worst = `bone ${a.header.bones[i]} frame ${f}`
        }
      }
    })
    slotMap.forEach((j, i) => {
      if (j < 0) return
      if (fa.a[i] !== fb.a[j]) result.attachments++
      for (let k = 0; k < 4; k++) result.color = Math.max(result.color, Math.abs(fa.c[i * 4 + k] - fb.c[j * 4 + k]))
      const va = fa.v && fa.v[i], vb = fb.v && fb.v[j]
      if (va && vb && fa.a[i] === fb.a[j]) {
        if (va.length !== vb.length) result.attachments++
        else for (let k = 0; k < va.length; k++) result.vertices = Math.max(result.vertices, Math.abs(va[k] - vb[k]))
      }
    })
  }
  const ea = new Set(a.events), eb = new Set(b.events)
  result.events = [...ea].filter((e) => !eb.has(e)).length + [...eb].filter((e) => !ea.has(e)).length
  if (result.events) result.eventDiff = [...[...ea].filter((e) => !eb.has(e)).map((e) => '-' + e), ...[...eb].filter((e) => !ea.has(e)).map((e) => '+' + e)].slice(0, 6)
  return result
}

function report (title, pairs) {
  console.log(`\n${title}`)
  console.log('run'.padEnd(44), 'a..d'.padStart(9), 'x,y'.padStart(9), 'verts'.padStart(9), 'color'.padStart(9), 'att'.padStart(5), 'evt'.padStart(4))
  const totals = { abcd: 0, xy: 0, vertices: 0, color: 0, attachments: 0, events: 0 }
  for (const [id, r] of pairs) {
    const f = (v) => v.toExponential(1).padStart(9)
    console.log(id.padEnd(44), f(r.abcd), f(r.xy), f(r.vertices), f(r.color), String(r.attachments).padStart(5), String(r.events).padStart(4), r.xy > 1e-3 ? r.worst : '', r.eventDiff ? r.eventDiff.join(' | ') : '')
    for (const k in totals) totals[k] = k === 'attachments' || k === 'events' ? totals[k] + r[k] : Math.max(totals[k], r[k])
  }
  console.log('max'.padEnd(44), ...['abcd', 'xy', 'vertices', 'color'].map((k) => totals[k].toExponential(1).padStart(9)), String(totals.attachments).padStart(5), String(totals.events).padStart(4))
}

const thePlan = plan()
const planPath = path.join(outDir, 'plan.json')
fs.writeFileSync(planPath, JSON.stringify(thePlan))

// The runtime's two files with the dumper, built as the games build them.
const posedump = path.join(outDir, 'posedump')
execFileSync('swiftc', ['-O', '-swift-version', '5', '-default-isolation', 'MainActor',
  path.join(sources, 'RigData.swift'), path.join(sources, 'RigPose.swift'),
  path.join(__dirname, 'PoseDump/main.swift'), '-o', posedump], { stdio: 'inherit' })

const dir = (name) => { const d = path.join(outDir, name); fs.mkdirSync(d, { recursive: true }); return d }
const ids = thePlan.runs.map((r) => r.id)

if (spineCore) {
  execFileSync(posedump, [planPath, dir('swift42'), '42'], { stdio: 'inherit' })
  execFileSync('node', [path.join(__dirname, 'spine42-dump.mjs'), planPath, dir('core42'), spineCore], { stdio: 'inherit' })
  report('RigPose (4.2) vs spine-core 4.2', ids.map((id) => [id, compare(readRun(path.join(outDir, 'swift42', `${id}.jsonl`)), readRun(path.join(outDir, 'core42', `${id}.jsonl`)))]))
} else {
  console.log('(skipping spine-core 4.2: pass --spine-core <dir of @esotericsoftware/spine-core>)')
}

if (spineC && fs.existsSync(spineC)) {
  // 3.6 played without crossfades or travel.
  const plain36 = { rigsDir, runs: thePlan.runs.filter((r) => !r.mix && !r.drift) }
  const plan36 = path.join(outDir, 'plan36.json')
  fs.writeFileSync(plan36, JSON.stringify(plain36))
  const ids36 = plain36.runs.map((r) => r.id)
  execFileSync(posedump, [plan36, dir('swift36'), '36'], { stdio: 'inherit' })
  const spinec = path.join(outDir, 'spine36dump')
  const spinecDouble = path.join(outDir, 'spine36dump-double')
  const include = dir('include')
  try { fs.symlinkSync(spineC, path.join(include, 'spine')) } catch {}
  const cSources = fs.readdirSync(spineC).filter((f) => f.endsWith('.c')).map((f) => path.join(spineC, f))
  const build = (output, flags) => execFileSync('cc', ['-O1', '-w', ...flags, '-I', include, ...cSources,
    path.join(__dirname, 'spine36-dump.c'), '-o', output, '-lm'], { stdio: 'inherit' })
  build(spinec, [])
  // The same code in double precision (its float maths functions too), which
  // separates float32 rounding (times drift over long runs) from logic.
  build(spinecDouble, ['-Dfloat=double', '-U__STDC_VERSION__'])
  const converted = dir('converted36')
  execFileSync('node', [path.join(__dirname, 'spine36-convert.js'), rigsDir, converted], { stdio: 'inherit' })
  execFileSync(spinecDouble, [plan36, dir('c36double'), converted], { stdio: 'inherit' })
  report('RigPose (3.6) vs spine-c 3.6 in double precision',
    ids36.map((id) => [id, compare(readRun(path.join(outDir, 'swift36', `${id}.jsonl`)), readRun(path.join(outDir, 'c36double', `${id}.jsonl`)))]))
  execFileSync(spinec, [plan36, dir('c36'), converted], { stdio: 'inherit' })
  report('RigPose (3.6) vs spine-c 3.6 in float',
    ids36.map((id) => [id, compare(readRun(path.join(outDir, 'swift36', `${id}.jsonl`)), readRun(path.join(outDir, 'c36', `${id}.jsonl`)))]))
} else {
  console.log('(skipping spine-c 3.6: pass --spine-c <dir of its sources>)')
}
