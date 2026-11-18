// Writes rigs' Spine 4.2 JSON back as Spine 3.6 JSON, with each key's curve
// recovered the way RigData recovers it (one normalized bezier per key, read
// from the value that moves most), so spine-c 3.6 can play exactly what
// RigPose's 3.6 mode plays.
//
//   node spine36-convert.js <dir of Rig<Name>.json skeletons> <out dir>

const fs = require('fs')
const path = require('path')

const [rigsDir, outDir] = process.argv.slice(2)

const inherits = { onlyTranslation: 'onlyTranslation', noRotationOrReflection: 'noRotationOrReflection', noScale: 'noScale', noScaleOrReflection: 'noScaleOrReflection' }

function color (hex) {
  const v = parseInt(hex.slice(0, 8).padEnd(8, 'f'), 16)
  return [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255].map((c) => c / 255)
}

// keys: 4.2 keys; values(key) -> the channel values; returns 3.6 keys built by make(key, values).
function convertKeys (keys, values, make, deform = false) {
  return keys.map((key, i) => {
    const out = make(key, values(key))
    out.time = key.time || 0
    if (key.curve === 'stepped') out.curve = 'stepped'
    else if (Array.isArray(key.curve) && i + 1 < keys.length) {
      const next = keys[i + 1]
      const t0 = key.time || 0, t1 = next.time || 0
      const v0 = deform ? [0] : values(key), v1 = deform ? [1] : values(next)
      let best = 0, range = 0
      for (let c = 0; c < v0.length; c++) {
        if (Math.abs(v1[c] - v0[c]) > range) { best = c; range = Math.abs(v1[c] - v0[c]) }
      }
      const h = key.curve.slice(best * 4, best * 4 + 4)
      const dt = t1 - t0
      const cx1 = dt !== 0 ? (h[0] - t0) / dt : 0, cx2 = dt !== 0 ? (h[2] - t0) / dt : 1
      let cy1 = cx1, cy2 = cx2
      if (range > 0) {
        cy1 = (h[1] - v0[best]) / (v1[best] - v0[best])
        cy2 = (h[3] - v0[best]) / (v1[best] - v0[best])
      }
      out.curve = [cx1, cy1, cx2, cy2]
    }
    return out
  })
}

function convert (json) {
  const out = { skeleton: { hash: '', spine: '3.6.53', width: 0, height: 0 } }
  out.bones = json.bones.map((b) => {
    const bone = { name: b.name }
    if (b.parent) bone.parent = b.parent
    for (const k of ['length', 'x', 'y', 'rotation', 'scaleX', 'scaleY', 'shearX', 'shearY']) if (b[k] !== undefined) bone[k] = b[k]
    if (inherits[b.inherit]) bone.transform = inherits[b.inherit]
    return bone
  })
  out.slots = json.slots.map((s) => ({ ...s }))
  if (json.ik) out.ik = json.ik.map((c) => ({ ...c, order: c.order || 0 }))
  if (json.path) {
    out.path = json.path.map((c) => {
      const p = { name: c.name, order: c.order || 0, bones: c.bones, target: c.target }
      for (const k of ['positionMode', 'spacingMode', 'rotateMode', 'rotation', 'position', 'spacing']) if (c[k] !== undefined) p[k] = c[k]
      if (c.mixRotate !== undefined) p.rotateMix = c.mixRotate
      if (c.mixX !== undefined) p.translateMix = c.mixX
      return p
    })
  }
  out.skins = {}
  for (const skin of json.skins) out.skins[skin.name] = skin.attachments
  out.animations = {}
  for (const [name, a] of Object.entries(json.animations)) {
    const anim = {}
    if (a.slots) {
      anim.slots = {}
      for (const [slot, timelines] of Object.entries(a.slots)) {
        const t = {}
        for (const [type, keys] of Object.entries(timelines)) {
          if (type === 'attachment') t.attachment = keys.map((k) => ({ time: k.time || 0, name: k.name === undefined ? null : k.name }))
          else if (type === 'rgba') t.color = convertKeys(keys, (k) => color(k.color), (k) => ({ color: k.color }))
          else throw new Error(`slot timeline ${type} not converted`)
        }
        anim.slots[slot] = t
      }
    }
    if (a.bones) {
      anim.bones = {}
      for (const [bone, timelines] of Object.entries(a.bones)) {
        const t = {}
        for (const [type, keys] of Object.entries(timelines)) {
          if (type === 'rotate') t.rotate = convertKeys(keys, (k) => [k.value || 0], (k, v) => ({ angle: v[0] }))
          else if (type === 'translate' || type === 'shear') t[type] = convertKeys(keys, (k) => [k.x || 0, k.y || 0], (k, v) => ({ x: v[0], y: v[1] }))
          else if (type === 'scale') t.scale = convertKeys(keys, (k) => [k.x ?? 1, k.y ?? 1], (k, v) => ({ x: v[0], y: v[1] }))
          else throw new Error(`bone timeline ${type} not converted`)
        }
        anim.bones[bone] = t
      }
    }
    if (a.attachments) {
      anim.deform = {}
      for (const [skin, slots] of Object.entries(a.attachments)) {
        anim.deform[skin] = {}
        for (const [slot, attachments] of Object.entries(slots)) {
          anim.deform[skin][slot] = {}
          for (const [attachment, timelines] of Object.entries(attachments)) {
            anim.deform[skin][slot][attachment] = convertKeys(timelines.deform, () => [0], (k) => {
              const key = {}
              if (k.offset !== undefined) key.offset = k.offset
              if (k.vertices !== undefined) key.vertices = k.vertices
              return key
            }, true)
          }
        }
      }
    }
    for (const k of ['ik', 'transform', 'path', 'drawOrder', 'events']) if (a[k]) throw new Error(`${k} timelines not converted`)
    out.animations[name] = anim
  }
  return out
}

fs.mkdirSync(outDir, { recursive: true })
for (const file of fs.readdirSync(rigsDir).filter((f) => /^Rig.*\.json$/.test(f))) {
  const json = JSON.parse(fs.readFileSync(path.join(rigsDir, file), 'utf8'))
  if (!json.bones) continue
  try {
    fs.writeFileSync(path.join(outDir, file), JSON.stringify(convert(json)))
  } catch (error) {
    console.log(`${file}: not converted (${error.message})`)
  }
}
