// paperd アプリアイコン「星座ネットワーク」ジェネレータ（案4 / 2026-06採用）。
// 自著被引用ネットワーク画面（ダーク背景 + 金色ハブ + 水色ノード）の美学と揃える。
// 使い方: scripts/make-appicon.sh（全サイズ描画 → AppIcon.icns）
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    let s = canvas / 512  // 基準512pxからのスケール
    let margin = 44 * s
    let rect = NSRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)

    // squircle背景: 夜空のグラデーション
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    bg.addClip()
    NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.30, alpha: 1),
        ending: NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.12, alpha: 1)
    )!.draw(in: rect, angle: -90)

    func dot(_ c: NSPoint, _ r: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }
    func line(_ a: NSPoint, _ b: NSPoint, _ color: NSColor, _ width: CGFloat) {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b)
        color.setStroke(); p.lineWidth = width; p.lineCapStyle = .round; p.stroke()
    }

    // 遠景の微小な星（奥行き）
    let faintStars: [(CGFloat, CGFloat, CGFloat)] = [
        (110, 388, 4), (392, 408, 3), (150, 120, 3), (404, 120, 4), (256, 430, 3), (84, 250, 3),
    ]
    for (x, y, r) in faintStars {
        dot(NSPoint(x: x * s, y: y * s), r * s, NSColor.white.withAlphaComponent(0.25))
    }

    let mid = NSPoint(x: rect.midX, y: rect.midY)
    let hub = NSPoint(x: mid.x - 18 * s, y: mid.y - 10 * s)
    let stars = [
        NSPoint(x: mid.x - 120 * s, y: mid.y + 96 * s), NSPoint(x: mid.x + 56 * s, y: mid.y + 120 * s),
        NSPoint(x: mid.x + 132 * s, y: mid.y + 24 * s), NSPoint(x: mid.x + 96 * s, y: mid.y - 110 * s),
        NSPoint(x: mid.x - 60 * s, y: mid.y - 128 * s), NSPoint(x: mid.x - 138 * s, y: mid.y - 36 * s),
    ]
    for star in stars { line(hub, star, NSColor.cyan.withAlphaComponent(0.45), 4 * s) }
    line(stars[0], stars[5], NSColor.cyan.withAlphaComponent(0.25), 3 * s)
    line(stars[2], stars[3], NSColor.cyan.withAlphaComponent(0.25), 3 * s)
    for star in stars { dot(star, 11 * s, NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.95, alpha: 1)) }

    // 金色ハブ（同心円グロー → ラジアル中心）
    for factor in [2.6, 1.9, 1.4] as [CGFloat] {
        dot(hub, 26 * factor * s, NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.2, alpha: 0.10))
    }
    dot(hub, 26 * s, NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.25, alpha: 1))
    dot(NSPoint(x: hub.x - 8 * s, y: hub.y + 8 * s), 10 * s, NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.6, alpha: 0.9))

    NSGraphicsContext.current?.restoreGraphicsState()
    image.unlockFocus()
    return image
}

func save(_ image: NSImage, _ filename: String, pixels: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
}

// iconset規格の全サイズ
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = base * scale
    let image = drawIcon(canvas: CGFloat(pixels))
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    save(image, name, pixels: pixels)
    print("✓ \(name)")
}
