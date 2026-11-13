// A module named Metal, so `SolutionFilm`'s `import Metal` resolves on
// Android. What it uses — a device, a queue, command buffers, a render pass
// and textures — is SpriteKitShim's stand-in, which the GLES renderer draws
// (`MetalExecution`); see `Android/Sources/SpriteKitShim/Metal.swift`.
@_exported import SpriteKitShim
