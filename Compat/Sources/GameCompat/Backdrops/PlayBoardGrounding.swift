import Foundation
import SpriteKitShim

// What a world shows round its board — the contact shadow, the patch of
// ground, Castle's cushion of puffs, Ruins' waterline, the green worlds'
// tufts and the Mainframe's pins — hung on the port's board as the real
// `BoardNode.init` hangs it (lines 191–265 there), from the game's own
// `BoardGroundingArt`, `CloudCushion`, `WaterlineArt`, `TuftArt` and
// `PinArt`. The port's board stands in for `BoardNode` until the scenes ring
// brings the real one, and this goes with it then.
extension PlayBoardNode {
    func ground(_ frame: BoardFrameNode, theme: WorldTheme) {
        let grounding = BoardGrounding.shown(in: theme)
        let cell = metrics.cell
        let cellMetrics = metrics
        let area = { (point: GridPoint) -> CGRect in
            let center = cellMetrics.point(point)
            return rect(center.x - cell / 2, center.y - cell / 2, cell, cell)
        }
        // `ConveyorNode.channels(…).keys` in the real one: the currents' cells.
        let currents = Set((level.conveyors ?? []).map { GridPoint($0.x, $0.y) })
        let cells = outline.cells
        let kerbs = Array(frame.pieceFrames.indices)
        if let look = theme.palette.grounding, !grounding.isDisjoint(with: [.shadow, .patch]) {
            let parts = BoardGroundingArt.parts(
                cells: cells.filter { !currents.contains($0) }.map(area),
                kerbs: frame.pieceFrames,
                openings: cells.filter(currents.contains).map(area),
                cell: cell,
                look: look,
                pieces: grounding
            )
            for (index, shares) in parts.enumerated() {
                for share in shares { frame.attach(share.node, toKerb: kerbs[index], z: share.z) }
            }
            if grounding.contains(.patch), look.puffs, let sea = CloudSeaNode.look(for: theme) {
                let cushion = CloudCushion(look: sea)
                if let node = BoardGroundingArt.cushion(
                    cells: cells.filter { !currents.contains($0) }.map(area),
                    kerbs: frame.pieceFrames,
                    openings: cells.filter(currents.contains).map(area),
                    cell: cell,
                    cushion: cushion
                ) {
                    node.zPosition = DesignSystem.groundingPatchZ
                    frame.addChild(node)
                }
                self.cushion = cushion
                run(cushion.follow(), withKey: "board.cushion")
            }
        }
        if grounding.contains(.waterline), let pool = TemplePoolNode.look(for: theme) {
            for (index, pieces) in WaterlineArt.parts(frame: frame, cell: cell, look: pool).enumerated() {
                for piece in pieces { frame.attach(piece.node, toKerb: index, z: piece.z) }
            }
        }
        if grounding.contains(.tufts), let tufts = LawnKit.kit(for: theme)?.pieces(.tuft), !tufts.isEmpty {
            for (index, pieces) in TuftArt.parts(frame: frame, tufts: tufts, theme: theme).enumerated() {
                for piece in pieces { frame.attach(piece.node, toKerb: index, z: piece.z) }
            }
        }
        if grounding.contains(.pins), !LaunchArguments.keysBackdrop {
            for (index, pieces) in PinArt.parts(frame: frame, cells: cells.map(area), cell: cell, theme: theme).enumerated() {
                for piece in pieces { frame.attach(piece.node, toKerb: index, z: piece.z) }
            }
        }
    }

    /// The board's shape, cell by cell and kerb by kerb, placed at `scale`
    /// and `position` in its parent (`BoardNode.silhouette(at:)`).
    func silhouette(scale: CGFloat, position: CGPoint) -> [CGRect] {
        let cell = metrics.cell
        let cells = outline.cells.map { point -> CGRect in
            let center = metrics.point(point)
            return rect(center.x - cell / 2, center.y - cell / 2, cell, cell)
        }
        return (cells + (frameNode?.pieceFrames ?? [])).map { area in
            rect(position.x + area.minX * scale, position.y + area.minY * scale, area.width * scale, area.height * scale)
        }
    }
}
