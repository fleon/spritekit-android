// A module named QuartzCore, so a game file's `import QuartzCore` resolves
// on Android as its `import SpriteKit` and `import UIKit` do.
//
// What this offers is `CACurrentMediaTime()`, the monotonic clock behind a
// game's own timing, every shader's `u_time` and the actions. There must be exactly one of it, so this is the
// shim's clock rather than a second one — see `SpriteKitShim.MediaTime`.
@_exported import SpriteKitShim
