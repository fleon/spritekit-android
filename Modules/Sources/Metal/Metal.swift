// A module named Metal, so a game file's `import Metal` resolves on Android.
// What it offers — a device, a queue, command buffers, a render pass and
// textures, as far as an `SKRenderer` needs them — is SpriteKitShim's
// stand-in, which the GLES renderer draws (`MetalExecution`); see
// `Sources/SpriteKitShim/Metal.swift`.
@_exported import SpriteKitShim
