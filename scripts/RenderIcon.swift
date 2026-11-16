import AppKit
import Foundation

/// 业务作用：从可维护几何定义生成应用图标，不依赖浏览器或第三方运行环境。
/// 参数说明:
/// - size: 目标图标像素边长。
/// 返回：带透明外边距的 PNG 字节。
func renderIcon(size: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw NSError(domain: "Nate.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(
        roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
        xRadius: 208,
        yRadius: 208
    )
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.025, green: 0.31, blue: 0.77, alpha: 1),
        ending: NSColor(srgbRed: 0.22, green: 0.62, blue: 0.98, alpha: 1)
    )
    gradient?.draw(in: background, angle: 90)
    let n = NSBezierPath()
    n.move(to: NSPoint(x: 298, y: 272))
    for point in [
        NSPoint(x: 298, y: 740), NSPoint(x: 388, y: 740), NSPoint(x: 636, y: 410),
        NSPoint(x: 636, y: 740), NSPoint(x: 726, y: 740), NSPoint(x: 726, y: 272),
        NSPoint(x: 636, y: 272), NSPoint(x: 388, y: 602), NSPoint(x: 388, y: 272),
    ] {
        n.line(to: point)
    }
    n.close()
    NSColor.white.setFill()
    n.fill()
    let caret = NSBezierPath()
    caret.move(to: NSPoint(x: 770, y: 734))
    caret.line(to: NSPoint(x: 828, y: 734))
    caret.move(to: NSPoint(x: 799, y: 734))
    caret.line(to: NSPoint(x: 799, y: 284))
    caret.move(to: NSPoint(x: 770, y: 284))
    caret.line(to: NSPoint(x: 828, y: 284))
    caret.lineWidth = 20
    caret.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.72).setStroke()
    caret.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Nate.Icon", code: 2)
    }
    return png
}

let directory = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icons"
)
let iconset = directory.appendingPathComponent("Nate.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try renderIcon(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try renderIcon(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try renderIcon(size: 1024).write(to: directory.appendingPathComponent("nate-1024.png"))
