// Stands in for the system UIKit module on Android. The game's presentation
// files import UIKit almost entirely for UIColor, which SpriteKitShim vends;
// anything else they reach for will fail here, loudly, which is the point.
@_exported import SpriteKitShim
