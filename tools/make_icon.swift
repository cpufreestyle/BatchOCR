import AppKit

// 用法: bo_icon <size> <out.png>   —— 生成 BatchOCR 应用图标（矢量绘制后按需栅格化）
let a = CommandLine.arguments
guard a.count >= 3, let size = Int(a[1]) else { fputs("usage: bo_icon <size> <out.png>\n", stderr); exit(1) }
let outPath = a[2]
let s = CGFloat(size) / 1024.0

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// 背景：圆角方块 + 竖直渐变（深蓝 -> 青）
let inset = 40.0 * s
let bgRect = NSRect(x: inset, y: inset, width: 1024 * s - inset * 2, height: 1024 * s - inset * 2)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 200 * s, yRadius: 200 * s)
let grad = NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.32, blue: 0.72, alpha: 1),
                               NSColor(srgbRed: 0.13, green: 0.62, blue: 0.78, alpha: 1)])!
grad.draw(in: bg, angle: -90)

// 文档纸张（带折角）
let paper = NSBezierPath()
let px = 300.0 * s, py = 260.0 * s, pw = 430.0 * s, ph = 500.0 * s
let fold = 110.0 * s
paper.move(to: NSPoint(x: px, y: py))
paper.line(to: NSPoint(x: px + pw - fold, y: py))
paper.line(to: NSPoint(x: px + pw, y: py + fold))
paper.line(to: NSPoint(x: px + pw, y: py + ph))
paper.line(to: NSPoint(x: px, y: py + ph))
paper.close()
NSColor.white.setFill()
paper.fill()

// 折角三角
let corner = NSBezierPath()
corner.move(to: NSPoint(x: px + pw - fold, y: py))
corner.line(to: NSPoint(x: px + pw, y: py + fold))
corner.line(to: NSPoint(x: px + pw - fold, y: py + fold))
corner.close()
NSColor(srgbRed: 0.80, green: 0.87, blue: 0.94, alpha: 1).setFill()
corner.fill()

// 文字 OCR
let text = "OCR"
let font = NSFont.systemFont(ofSize: 176 * s, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(srgbRed: 0.08, green: 0.30, blue: 0.60, alpha: 1),
]
let str = NSAttributedString(string: text, attributes: attrs)
let textSize = str.size()
str.draw(at: NSPoint(x: px + (pw - textSize.width) / 2, y: py + 92 * s))

// 扫描线（三条，示意识别）
NSColor(srgbRed: 0.55, green: 0.66, blue: 0.78, alpha: 1).setFill()
for i in 0..<2 {
    let w = (pw - 120 * s) * (i == 1 ? 0.62 : 1.0)
    NSRect(x: px + 60 * s, y: py + ph - 92 * s - CGFloat(i) * 62 * s, width: w, height: 26 * s).fill()
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
