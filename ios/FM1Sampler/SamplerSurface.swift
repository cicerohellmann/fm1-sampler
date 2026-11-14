import SwiftUI
import UIKit

struct SamplerSurface: View {
    @ObservedObject var model: SamplerModel
    @State private var gestureStarted = false
    @GestureState private var gestureActive = false

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            let scale = (portrait ? proxy.size.width : proxy.size.height) / 400
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 20.0 / 255.0, green: 20.0 / 255.0, blue: 26.0 / 255.0)))
                var current = context
                var saved: [GraphicsContext] = []
                for op in model.operations {
                    let v = op.values.map { $0 * scale }
                    let color = Color(argb: op.argb)
                    switch op.type {
                    case 0, 1:
                        let rect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                        let path = Path(roundedRect: rect, cornerRadius: v[4])
                        if op.type == 0 { current.fill(path, with: .color(color)) }
                        else { current.stroke(path, with: .color(color), lineWidth: v[5]) }
                    case 2:
                        guard let i = op.textIndex, i < model.texts.count else { continue }
                        let raw = op.values
                        current.withCGContext { cgContext in
                            UIGraphicsPushContext(cgContext)
                            drawText(model.texts[i], x: raw[0], baseline: raw[1], size: raw[2],
                                     align: Int(raw[3]), bold: raw[4] != 0,
                                     color: UIColor(argb: op.argb), d: scale)
                            UIGraphicsPopContext()
                        }
                    case 3:
                        var path = Path(); path.move(to: CGPoint(x: v[0], y: v[1])); path.addLine(to: CGPoint(x: v[2], y: v[3]))
                        current.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: v[4], lineCap: .round))
                    case 4:
                        let rect = CGRect(x: v[0] - v[2], y: v[1] - v[2], width: 2 * v[2], height: 2 * v[2])
                        current.fill(Path(ellipseIn: rect), with: .color(color))
                    case 5:
                        var path = Path(); path.move(to: CGPoint(x: v[0], y: v[1])); path.addLine(to: CGPoint(x: v[2], y: v[3])); path.addLine(to: CGPoint(x: v[4], y: v[5])); path.closeSubpath()
                        current.fill(path, with: .color(color))
                    case 6:
                        saved.append(current)
                        current.clip(to: Path(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
                    case 7:
                        if let previous = saved.popLast() { current = previous }
                    default: break
                    }
                }
            }
            .onAppear { model.updateFrame(width: proxy.size.width, height: proxy.size.height, top: proxy.safeAreaInsets.top, bottom: proxy.safeAreaInsets.bottom) }
            .onChange(of: proxy.size) { newSize in model.updateFrame(width: newSize.width, height: newSize.height, top: proxy.safeAreaInsets.top, bottom: proxy.safeAreaInsets.bottom) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($gestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        let action = gestureStarted ? 1 : 0
                        gestureStarted = true
                        model.touch(action: action, x: value.location.x / scale, y: value.location.y / scale)
                    }
                    .onEnded { value in
                        if gestureStarted {
                            model.touch(action: 2, x: value.location.x / scale, y: value.location.y / scale)
                            gestureStarted = false
                        }
                    }
            )
            .onChange(of: gestureActive) { active in
                if !active && gestureStarted {
                    gestureStarted = false
                    model.touch(action: 2, x: 0, y: 0)
                }
            }
        }
    }

    private func drawText(_ s: String, x: CGFloat, baseline: CGFloat, size: CGFloat,
                          align: Int, bold: Bool, color: UIColor, d: CGFloat) {
        let font = UIFont.monospacedSystemFont(ofSize: size * d,
                                               weight: bold ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let w = (s as NSString).size(withAttributes: attrs).width
        let px = x * d
        let left = align == 1 ? px - w / 2 : align == 2 ? px - w : px
        (s as NSString).draw(at: CGPoint(x: left, y: baseline * d - font.ascender),
                             withAttributes: attrs)
    }
}

extension Color {
    init(argb: UInt32) {
        self.init(.sRGB, red: Double((argb >> 16) & 0xff) / 255, green: Double((argb >> 8) & 0xff) / 255, blue: Double(argb & 0xff) / 255, opacity: Double((argb >> 24) & 0xff) / 255)
    }
}

private extension UIColor {
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xff) / 255,
                  green: CGFloat((argb >> 8) & 0xff) / 255,
                  blue: CGFloat(argb & 0xff) / 255,
                  alpha: CGFloat((argb >> 24) & 0xff) / 255)
    }
}
