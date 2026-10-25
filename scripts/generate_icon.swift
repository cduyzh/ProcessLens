#!/usr/bin/env swift
import AppKit
import Foundation

// 原创矢量绘制，所有尺寸均由 1024 点设计坐标直接重绘。
// 用法：swift scripts/generate_icon.swift [资源目录]
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
let fileManager = FileManager.default
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
}

func gradient(_ path: NSBezierPath, _ first: UInt32, _ last: UInt32, angle: CGFloat = -90) {
    NSGradient(starting: color(first), ending: color(last))!.draw(in: path, angle: angle)
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconRenderer", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    // 雾白圆角底板：边缘留透明安全区，与系统 Dock 图标保持一致。
    let plate = rounded(72, 72, 880, 880, 196)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -16), blur: 24, color: color(0x25344A, 0.18).cgColor)
    gradient(plate, 0xFBFCFF, 0xE4EAF1)
    cg.restoreGState()
    plate.lineWidth = 2
    color(0xFFFFFF, 0.95).setStroke()
    plate.stroke()

    // 柔和的局部色彩反射，不使用文字或装饰性标识。
    cg.saveGState()
    plate.addClip()
    NSGradient(colors: [color(0xA8F8DF, 0.22), color(0xA8F8DF, 0)])!
        .draw(fromCenter: NSPoint(x: 750, y: 690), radius: 0,
              toCenter: NSPoint(x: 750, y: 690), radius: 405, options: .drawsAfterEndingLocation)
    cg.restoreGState()

    // 处理器两侧的四组引脚采用低对比金属色，缩小时保持主轮廓简洁。
    for y in [CGFloat(348), 444, 540, 636] {
        gradient(rounded(188, y, 83, 32, 12), 0xC6D1DC, 0xA3B0BE)
        gradient(rounded(753, y, 83, 32, 12), 0xC6D1DC, 0xA3B0BE)
    }
    for x in [CGFloat(348), 444, 540, 636] {
        gradient(rounded(x, 188, 32, 83, 12), 0xCED7E1, 0xA7B3C0)
        gradient(rounded(x, 753, 32, 83, 12), 0xCED7E1, 0xA7B3C0)
    }

    let casing = rounded(234, 234, 556, 556, 114)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -20), blur: 28, color: color(0x172539, 0.27).cgColor)
    gradient(casing, 0x34455C, 0x182638)
    cg.restoreGState()
    casing.lineWidth = 3
    color(0x52647D).setStroke()
    casing.stroke()

    let screen = rounded(264, 264, 496, 496, 86)
    gradient(screen, 0x203447, 0x112330)
    screen.lineWidth = 2
    color(0x142032).setStroke()
    screen.stroke()

    cg.saveGState()
    screen.addClip()
    NSGradient(colors: [color(0x20D9AF, 0.16), color(0x20D9AF, 0)])!
        .draw(fromCenter: NSPoint(x: 560, y: 508), radius: 0,
              toCenter: NSPoint(x: 560, y: 508), radius: 275, options: .drawsAfterEndingLocation)
    // 一条极淡的水平基准线，强化“实时资源监测”的语义。
    let baseline = NSBezierPath()
    baseline.move(to: NSPoint(x: 301, y: 503))
    baseline.line(to: NSPoint(x: 725, y: 503))
    baseline.lineWidth = 2
    color(0x7A9CAC, 0.14).setStroke()
    baseline.stroke()
    cg.restoreGState()

    // 一笔实时脉冲：稳定 → 波峰 → 波谷 → 恢复，转角全部圆润。
    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 314, y: 503))
    pulse.line(to: NSPoint(x: 398, y: 503))
    pulse.line(to: NSPoint(x: 443, y: 564))
    pulse.line(to: NSPoint(x: 495, y: 411))
    pulse.line(to: NSPoint(x: 556, y: 636))
    pulse.line(to: NSPoint(x: 608, y: 503))
    pulse.line(to: NSPoint(x: 706, y: 503))
    pulse.lineWidth = 27
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 21, color: color(0x43E8BE, 0.35).cgColor)
    color(0x6CF0CC).setStroke()
    pulse.stroke()
    cg.restoreGState()

    // 青绿状态条与蓝紫指示灯形成品牌微标识。
    for (index, height) in [CGFloat(18), 31, 42].enumerated() {
        color(0x68EAC7, 0.42 + CGFloat(index) * 0.18).setFill()
        rounded(319 + CGFloat(index) * 28, 313, 13, height, 6.5).fill()
    }
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 12, color: color(0xA298FF, 0.4).cgColor)
    gradient(rounded(685, 675, 29, 29, 10), 0xB5ACFF, 0x8385E8)
    cg.restoreGState()

    // 顶缘微光，只占屏幕一小部分，保持材质克制。
    let highlight = NSBezierPath()
    highlight.move(to: NSPoint(x: 332, y: 736))
    highlight.curve(to: NSPoint(x: 607, y: 736), controlPoint1: NSPoint(x: 420, y: 740), controlPoint2: NSPoint(x: 530, y: 740))
    highlight.lineWidth = 2
    highlight.lineCapStyle = .round
    color(0x9DB7CA, 0.16).setStroke()
    highlight.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 2)
    }
    return png
}

let mainIcon = output.appendingPathComponent("AppIcon_1024.png")
try drawIcon(size: 1024).write(to: mainIcon)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try drawIcon(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try drawIcon(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", output.appendingPathComponent("AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconRenderer", code: Int(process.terminationStatus))
}
print("已生成 \(mainIcon.path) 与 AppIcon.icns")
