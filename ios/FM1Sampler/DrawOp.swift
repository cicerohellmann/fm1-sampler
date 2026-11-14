import CoreGraphics

struct DrawOp: Identifiable {
    let id: Int
    let type: Int
    let values: [CGFloat]
    let argb: UInt32
    let textIndex: Int?
}
