// A module named QuartzCore, so a game file's `import QuartzCore` resolves
// on Android as its `import SpriteKit` and `import UIKit` do.
//
// The game reaches QuartzCore for one thing: `CACurrentMediaTime()`, the
// monotonic clock behind `MediaClock`, every shader's `u_time` and the
// board's action timings. There must be exactly one of it, so this is the
// shim's clock rather than a second one — see `SpriteKitShim.MediaTime`.
@_exported import SpriteKitShim
