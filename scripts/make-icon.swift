#!/usr/bin/env swift
// 生成 1024x1024 的 App 图标 PNG。用法：swift scripts/make-icon.swift out.png
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
let side = CGFloat(size)

guard let rep = NSBitmapImageRep(
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
) else {
    FileHandle.standardError.write("无法创建位图\n".data(using: .utf8)!)
    exit(1)
}

rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 背景：靛蓝到紫的斜向渐变，圆角方（macOS 图标习惯留出约 8% 边距）
let inset: CGFloat = 84
let span = side - inset * 2
let body = NSRect(x: inset, y: inset, width: span, height: span)
let rounded = NSBezierPath(roundedRect: body, xRadius: 196, yRadius: 196)

NSGraphicsContext.saveGraphicsState()
rounded.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.33, blue: 0.94, alpha: 1),
    NSColor(srgbRed: 0.64, green: 0.35, blue: 0.93, alpha: 1)
])
gradient?.draw(in: body, angle: -55)
NSGraphicsContext.restoreGraphicsState()

// 白色 “M” 字母，用系统最粗字重
let font = NSFont.systemFont(ofSize: 430, weight: .heavy)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)

let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .shadow: shadow
]
let attributed = NSAttributedString(string: "M", attributes: attributes)
let textSize = attributed.size()
let textRect = NSRect(
    x: (side - textSize.width) / 2,
    y: (side - textSize.height) / 2 + 76,
    width: textSize.width,
    height: textSize.height
)
attributed.draw(in: textRect)

// 下面三条递减的白色短线，暗示“文字”，也让图标不只一个字母
let barHeight: CGFloat = 30
let bars: [(width: CGFloat, alpha: CGFloat)] = [(300, 0.92), (220, 0.72), (140, 0.52)]
var barY = textRect.minY - 92
for bar in bars {
    let rect = NSRect(
        x: (side - bar.width) / 2,
        y: barY,
        width: bar.width,
        height: barHeight
    )
    NSColor.white.withAlphaComponent(bar.alpha).setFill()
    NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    barY -= 52
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成 \(outputPath)")
