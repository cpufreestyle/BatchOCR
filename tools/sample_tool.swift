//
//  sample_tool — 验证辅助工具
//  gen     : 生成"仿真扫描件"（纯图片、无文字层的 PDF，内容为中英文票据/报告）
//  inspect : 输出 PDF 的页数与可提取文字字符数（用于断言 OCR 是否成功生成文字层）
//

import Foundation
import CoreGraphics
import CoreText
import PDFKit

let W = 1654, H = 2339   // A4 @ 200dpi
let PAGE = CGRect(x: 0, y: 0, width: 595.5, height: 842)

struct Line { let text: String; let size: CGFloat }

let enLines: [Line] = [
    Line(text: "INVOICE", size: 56),
    Line(text: "Invoice Number: INV-2026-0930", size: 38),
    Line(text: "Total Amount Due: $1,234.56", size: 38),
    Line(text: "Date: September 30, 2026", size: 38),
    Line(text: "Billed To: Acme Corporation", size: 38),
    Line(text: "Payment Terms: Net 30 days", size: 38),
    Line(text: "Bank Account: 6222 0000 1234 5678", size: 38),
    Line(text: "Thank you for your business.", size: 38),
]

let zhLines: [Line] = [
    Line(text: "发 票", size: 56),
    Line(text: "发票号码：INV-2026-0930", size: 38),
    Line(text: "总金额：人民币壹仟贰佰叁拾肆元伍角陆分", size: 38),
    Line(text: "开票日期：2026年9月30日", size: 38),
    Line(text: "客户名称：创新科技有限公司", size: 38),
    Line(text: "付款方式：银行转账", size: 38),
    Line(text: "付款期限：三十日内付清", size: 38),
    Line(text: "谢谢惠顾", size: 38),
]

let mixedLines: [Line] = [
    Line(text: "Quarterly Report 2026 Q3", size: 52),
    Line(text: "季度报告：第三季度", size: 38),
    Line(text: "Revenue increased by 12.5 percent", size: 38),
    Line(text: "营收增长百分之十二点五", size: 38),
    Line(text: "Contact: support@example.com", size: 38),
    Line(text: "联系电话：400-800-1234", size: 38),
    Line(text: "内部资料，请勿外传", size: 38),
]

func lines(for kind: String) -> [Line] {
    switch kind {
    case "en": return enLines
    case "zh": return zhLines
    default: return mixedLines
    }
}

func font(for kind: String, size: CGFloat) -> CTFont {
    let name = kind == "en" ? "Helvetica" : "PingFangSC-Regular"
    return CTFontCreateWithName(name as CFString, size, nil)
}

func renderPageImage(_ kind: String, pageNo: Int, totalPages: Int, stress: Bool = false) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    func drawText() {
        var y = H - 260
        for l in lines(for: kind) {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    font(for: kind, size: l.size),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(gray: 0.12, alpha: 1.0),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: l.text, attributes: attrs))
            ctx.textPosition = CGPoint(x: 150, y: y)
            CTLineDraw(line, ctx)
            y -= 110
        }

        let pageAttr: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: kind, size: 28),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1.0),
        ]
        let pageLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Scan Page \(pageNo)/\(totalPages)", attributes: pageAttr))
        ctx.textPosition = CGPoint(x: 150, y: 120)
        CTLineDraw(pageLine, ctx)
    }

    if stress {
        // 恶劣条件：整页内容旋转 2°（模拟没放正的扫描件）
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
        ctx.rotate(by: 2 * .pi / 180)
        ctx.translateBy(x: -CGFloat(W) / 2, y: -CGFloat(H) / 2)
        drawText()
        ctx.restoreGState()
        // 撒噪点（模拟纸张纹理/扫描噪声）
        for _ in 0..<40_000 {
            let x = CGFloat.random(in: 0..<CGFloat(W))
            let y = CGFloat.random(in: 0..<CGFloat(H))
            ctx.setFillColor(CGColor(gray: CGFloat.random(in: 0.2...0.85),
                                     alpha: CGFloat.random(in: 0.25...0.7)))
            ctx.fill(CGRect(x: x, y: y, width: 1.6, height: 1.6))
        }
    } else {
        drawText()
    }

    return ctx.makeImage()!
}

func gen(_ out: String, _ pages: Int, _ kind: String, stress: Bool = false) -> Bool {
    var box = PAGE
    guard let pdf = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &box, nil) else {
        print("无法创建 PDF：\(out)"); return false
    }
    for p in 1...max(1, pages) {
        let img = renderPageImage(kind, pageNo: p, totalPages: max(1, pages), stress: stress)
        pdf.beginPDFPage(nil)
        pdf.draw(img, in: PAGE)
        pdf.endPDFPage()
    }
    pdf.closePDF()
    print("已生成 \(out)（\(pages) 页，\(kind)）")
    return true
}

func inspect(_ path: String) -> Int32 {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        print("pages=0 chars=0 sample=（无法解析）")
        return 1
    }
    let s = doc.string ?? ""
    let sample = String(s.prefix(2000))
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    print("pages=\(doc.pageCount) chars=\(s.count) sample=\(sample)")
    return 0
}

// 顶层入口（单文件脚本模式编译）
let toolArgs = CommandLine.arguments
guard toolArgs.count >= 3 else {
    print("用法: sample_tool gen <out.pdf> <页数> <en|zh|mixed> | sample_tool inspect <file.pdf>")
    exit(2)
}
switch toolArgs[1] {
case "gen":
    let pages = toolArgs.count > 3 ? (Int(toolArgs[3]) ?? 1) : 1
    let kind = toolArgs.count > 4 ? toolArgs[4] : "mixed"
    let stress = toolArgs.count > 5 && toolArgs[5] == "stress"
    exit(gen(toolArgs[2], pages, kind, stress: stress) ? 0 : 1)
case "inspect":
    exit(inspect(toolArgs[2]))
default:
    print("未知命令：\(toolArgs[1])")
    exit(2)
}
