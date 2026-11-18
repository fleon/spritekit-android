// Plays the schedules in a verify-pose.js plan through spine-core 4.2 and
// writes each frame's pose as JSON lines, in posedump's format: positions
// relative to the skeleton's place, as RigPose gives them.
//
//   node spine42-dump.mjs <plan.json> <out dir> <spine-core package dir>

import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [planPath, outDir, coreDir] = process.argv.slice(2)
const spine = await import(pathToFileURL(path.join(coreDir, 'dist/index.js')).href)
const { SkeletonJson, Skeleton, AnimationState, AnimationStateData, RegionAttachment, MeshAttachment, ClippingAttachment,
  PathAttachment, BoundingBoxAttachment, PointAttachment, Physics } = spine

const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'))

// Regions as the rig's atlas has them: unrotated, untrimmed. Without an
// atlas size, any will do: only the vertices are compared.
function loaderFor (json) {
  const [width, height] = json.atlasSize || [4096, 4096]
  const region = (name) => {
    const [x, y, w, h] = (json.atlas || {})[name] || [0, 0, 1, 1]
    return { u: x / width, v: y / height, u2: (x + w) / width, v2: (y + h) / height, width: w, height: h,
      originalWidth: w, originalHeight: h, offsetX: 0, offsetY: 0, degrees: 0, texture: null }
  }
  return {
    newRegionAttachment (skin, name, p) { const a = new RegionAttachment(name, p); a.region = region(p); return a },
    newMeshAttachment (skin, name, p) { const a = new MeshAttachment(name, p); a.region = region(p); return a },
    newBoundingBoxAttachment (skin, name) { return new BoundingBoxAttachment(name) },
    newPathAttachment (skin, name) { return new PathAttachment(name) },
    newPointAttachment (skin, name) { return new PointAttachment(name) },
    newClippingAttachment (skin, name) { return new ClippingAttachment(name) }
  }
}

const num = (v) => (v === 0 || !Number.isFinite(v)) ? '0' : String(Number(v.toPrecision(7)))
const list = (values) => '[' + values.map(num).join(',') + ']'

const cache = new Map()
for (const run of plan.runs) {
  const scale = run.scale || 1
  const key = `${run.rig}@${scale}`
  let data = cache.get(key)
  if (!data) {
    const json = JSON.parse(fs.readFileSync(path.join(plan.rigsDir, `Rig${run.rig}.json`), 'utf8'))
    const reader = new SkeletonJson(loaderFor(json))
    reader.scale = scale
    data = reader.readSkeletonData(json)
    cache.set(key, data)
  }

  const skeleton = new Skeleton(data)
  skeleton.setToSetupPose()
  skeleton.updateWorldTransform(Physics.update)
  const stateData = new AnimationStateData(data)
  stateData.defaultMix = run.mix || 0
  const state = new AnimationState(stateData)
  let frame = 0
  const events = []
  state.addListener({
    start: (e) => events.push(`start ${e.trackIndex} ${e.animation.name} @${frame}`),
    interrupt: (e) => events.push(`interrupt ${e.trackIndex} ${e.animation.name} @${frame}`),
    end: (e) => events.push(`end ${e.trackIndex} ${e.animation.name} @${frame}`),
    complete: (e) => events.push(`complete ${e.trackIndex} ${e.animation.name} @${frame}`)
  })
  const drift = run.drift || [0, 0]

  let out = JSON.stringify({ bones: data.bones.map((b) => b.name), slots: data.slots.map((s) => s.name) }) + '\n'
  let buffer = []
  for (; frame < run.frames; frame++) {
    for (const action of run.actions) {
      if (action.frame !== frame) continue
      let entry = null
      if (action.op === 'add') entry = state.addAnimation(action.track || 0, action.name, !!action.loop, action.delay || 0)
      else if (action.op === 'origin') { skeleton.x = (action.x || 0) * scale; skeleton.y = (action.y || 0) * scale }
      else if (action.op === 'clear') state.clearTrack(action.track || 0)
      else entry = state.setAnimation(action.track || 0, action.name, !!action.loop)
      if (entry && action.mix !== undefined) entry.mixDuration = action.mix
      if (entry && action.timeScale !== undefined) entry.timeScale = action.timeScale
    }
    skeleton.x += drift[0] * scale
    skeleton.y += drift[1] * scale
    const dt = run.dts ? run.dts[frame % run.dts.length] : (run.dt || 1 / 60)
    state.update(dt)
    state.apply(skeleton)
    skeleton.update(dt)
    skeleton.updateWorldTransform(Physics.update)

    const ox = skeleton.x, oy = skeleton.y
    const bones = []
    for (const b of skeleton.bones) bones.push(b.a, b.b, b.c, b.d, b.worldX - ox, b.worldY - oy)
    const names = skeleton.slots.map((s) => s.attachment ? JSON.stringify(s.attachment.name) : 'null')
    const colors = []
    for (const s of skeleton.slots) {
      const c = s.color, k = skeleton.color
      const t = s.attachment && s.attachment.color && !(s.attachment instanceof ClippingAttachment) && !(s.attachment instanceof PathAttachment)
        ? s.attachment.color : { r: 1, g: 1, b: 1, a: 1 }
      colors.push(k.r * c.r * t.r, k.g * c.g * t.g, k.b * c.b * t.b, k.a * c.a * t.a)
    }
    let line = `{"f":${frame},"b":${list(bones)},"a":[${names.join(',')}],"c":${list(colors)}`
    if (frame % run.vertexEvery === 0) {
      const parts = []
      skeleton.slots.forEach((s, i) => {
        const a = s.attachment
        if (!a || a instanceof BoundingBoxAttachment || a instanceof PointAttachment) return
        if (a instanceof RegionAttachment) {
          buffer = new Array(8).fill(0)
          a.computeWorldVertices(s, buffer, 0, 2)
          // spine-c 3.6's order starts at the bottom right corner.
          buffer = [buffer[6], buffer[7], buffer[0], buffer[1], buffer[2], buffer[3], buffer[4], buffer[5]]
        } else {
          buffer = new Array(a.worldVerticesLength).fill(0)
          a.computeWorldVertices(s, 0, a.worldVerticesLength, buffer, 0, 2)
        }
        parts.push(`"${i}":${list(buffer.map((v, k) => v - (k % 2 ? oy : ox)))}`)
      })
      line += `,"v":{${parts.join(',')}}`
    }
    out += line + '}\n'
  }
  out += JSON.stringify({ events }) + '\n'
  fs.writeFileSync(path.join(outDir, `${run.id}.jsonl`), out)
}
