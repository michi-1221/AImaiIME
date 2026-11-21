// 入力メニューに表示するアイコン（icon.tiff）を作る。使い方: swift make-icon.swift <出力パス>
// デザイン: くっきりした「あ」の右上に、ぼやけた「あ」が煙のように立ちのぼる。
// 黒一色＋アルファで描き、Info.plist の TISIconIsTemplate でテンプレート画像として扱う
// （メニューバーの明暗に合わせて macOS が白か黒に塗り分ける）。
import AppKit
import CoreImage

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.tiff"
let pt: CGFloat = 16

/// scale 倍の画素で 16pt のアイコンを描く。ぼかしが切れないよう、余白つきのキャンバスに描いてから中央を切り出す。
func render(scale: CGFloat) -> NSBitmapImageRep {
    let n = Int(pt * scale), m = n * 2
    func canvas(_ draw: () -> Void) -> CIImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: m, pixelsHigh: m, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let t = NSAffineTransform(); t.translateX(by: CGFloat(n) / 2, yBy: CGFloat(n) / 2); t.scale(by: scale); t.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return CIImage(bitmapImageRep: rep)!
    }
    func glyph(dx: CGFloat, dy: CGFloat, size: CGFloat) {
        let t = NSAttributedString(string: "あ", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        let s = t.size()
        t.draw(at: NSPoint(x: pt / 2 - s.width / 2 + dx, y: pt / 2 - s.height / 2 + dy))
    }
    let sharp = canvas { glyph(dx: -0.8, dy: -0.8, size: 12) }
    let smoke = canvas { glyph(dx: 1.6, dy: 1.8, size: 12.6) }
        .applyingGaussianBlur(sigma: Double(0.9 * scale))
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55)])
    let img = sharp.composited(over: smoke)
    let cg = CIContext().createCGImage(img, from: CGRect(x: CGFloat(n) / 2, y: CGFloat(n) / 2, width: CGFloat(n), height: CGFloat(n)))!
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: pt, height: pt)
    return rep
}

let image = NSImage(size: NSSize(width: pt, height: pt))
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
try! image.tiffRepresentation!.write(to: URL(fileURLWithPath: out))
