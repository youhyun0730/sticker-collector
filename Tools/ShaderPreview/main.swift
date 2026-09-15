import AppKit
import Foundation
import Metal
import simd

// 加工シェーダーを PNG に焼き出すオフライン検証台。
//
// シミュレータを起動せずに「傾き × 個体」の一覧を作れるため、見た目の調整を
// 短い周期で回せる。アプリと同じ .metal を取り込んでいるので、ここで見えたものが
// そのまま実機に出る。ジャイロの手触りと実フレームレートだけは実機でしか分からない。
//
//   swift Tools/ShaderPreview/render.sh          # 既定の一覧を out/ に書く

// MARK: - 被写体と形状

enum PreviewSubject: String, CaseIterable {
    case paleFlat, graphic, sunset, white

    /// 淡い平坦はホロ箔が最も乗りにくい条件。調整では常にこれを見る。
    func draw(in ctx: CGContext, rect: CGRect) {
        switch self {
        case .white:
            ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
            ctx.fill(rect)
        case .paleFlat:
            drawGradient(ctx, rect, [(0.96, 0.96, 0.97), (0.86, 0.87, 0.90)])
            // 薄い格子。屈折で縁の像が詰まるかどうかは、直線が曲がる場所でしか読めない。
            ctx.setFillColor(CGColor(red: 0.74, green: 0.75, blue: 0.79, alpha: 0.55))
            let step = rect.width / 9
            let line = max(0.5, rect.width * 0.006)
            var x = rect.minX + step / 2
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: rect.minY, width: line, height: rect.height))
                x += step
            }
            var y = rect.minY + step / 2
            while y < rect.maxY {
                ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: line))
                y += step
            }
        case .sunset:
            // 暗部から白飛び寸前まで一気に振る縦のグラデーション。
            // 「物」に見える形は置かない。加工の筋と被写体の輪郭が見分けられなくなる。
            // 焼き出しは上下が反転するので、アプリ側（上が暗い）と揃うよう逆順で渡す。
            drawGradient(ctx, rect, [(0.99, 0.74, 0.42), (0.78, 0.33, 0.32),
                                     (0.32, 0.13, 0.33), (0.07, 0.06, 0.20)])
        case .graphic:
            ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1))
            ctx.fill(rect)
            let colors: [(CGFloat, CGFloat, CGFloat)] = [
                (1.0, 0.30, 0.45), (0.25, 0.85, 0.95), (1.0, 0.82, 0.25),
                (0.55, 0.40, 1.0), (0.30, 0.95, 0.55)
            ]
            for (index, c) in colors.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: rect.midX + CGFloat(index) * rect.width * 0.10 - rect.width * 0.20,
                                y: rect.midY)
                ctx.rotate(by: CGFloat(index) * 0.6 - 1.0)
                ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
                let bar = CGRect(x: -rect.width * 0.09, y: -rect.height * 0.9,
                                 width: rect.width * 0.18, height: rect.height * 1.8)
                ctx.addPath(CGPath(roundedRect: bar, cornerWidth: rect.width * 0.09,
                                   cornerHeight: rect.width * 0.09, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }

    private func drawGradient(_ ctx: CGContext, _ rect: CGRect, _ stops: [(CGFloat, CGFloat, CGFloat)]) {
        let colors = stops.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        let locations = stops.indices.map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: locations) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }
}

enum PreviewShape: String, CaseIterable {
    case bunny, squircle, circle, star, blob

    /// bunny は参考写真（ミッフィーのぷくぷくシール）と見比べるために置く。
    /// 耳のような細い突起は、輪郭に沿った盛り上がりが破綻しやすい形。
    func path(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height
        let cx = rect.midX, cy = rect.midY
        switch self {
        case .circle:
            return CGPath(ellipseIn: rect.insetBy(dx: w * 0.02, dy: h * 0.02), transform: nil)
        case .squircle:
            return CGPath(roundedRect: rect.insetBy(dx: w * 0.04, dy: h * 0.04),
                          cornerWidth: w * 0.30, cornerHeight: h * 0.30, transform: nil)
        case .star:
            let path = CGMutablePath()
            let outer = min(w, h) / 2 * 0.98
            let inner = outer * 0.46
            for i in 0..<10 {
                let r = i.isMultiple(of: 2) ? outer : inner
                let a = CGFloat(i) * .pi / 5 - .pi / 2
                let p = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        case .blob:
            let path = CGMutablePath()
            let base = min(w, h) / 2 * 0.95
            for i in 0...96 {
                let t = CGFloat(i) / 96 * 2 * .pi
                var r = base
                r += base * 0.06 * cos(t * 3 + 0.4)
                r += base * 0.05 * cos(t * 5 - 1.1)
                r += base * 0.04 * sin(t * 2 + 0.9)
                let p = CGPoint(x: cx + cos(t) * r, y: cy + sin(t) * r)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        case .bunny:
            let path = CGMutablePath()
            let head = min(w, h) * 0.34
            // 頭
            path.addEllipse(in: CGRect(x: cx - head, y: cy - head * 1.15, width: head * 2, height: head * 1.9))
            // 耳2本。細長い突起で、法線推定が最も苦しくなる。
            for sign in [CGFloat(-1), CGFloat(1)] {
                let earW = head * 0.42, earH = head * 1.5
                let ex = cx + sign * head * 0.44
                let ey = cy + head * 0.35
                let ear = CGMutablePath()
                ear.addRoundedRect(in: CGRect(x: -earW / 2, y: -earH / 2, width: earW, height: earH),
                                   cornerWidth: earW / 2, cornerHeight: earW / 2)
                var t = CGAffineTransform(translationX: ex, y: ey)
                    .rotated(by: sign * 0.18)
                if let rotated = ear.copy(using: &t) { path.addPath(rotated) }
            }
            return path
        }
    }
}

// MARK: - テクスチャの用意

/// SwiftUI の layerEffect と同じ条件を作る。
///
/// シェーダーが外側を参照できるよう透明の余白を付け、アルファ乗算済みで詰める。
/// 余白が無いと縁の法線推定が端で切れて、ぷっくりの縁が壊れる。
func makeSourceTexture(device: MTLDevice, size: Int, pad: Int,
                       subject: PreviewSubject, shape: PreviewShape) -> MTLTexture {
    let full = size + pad * 2
    let bytesPerRow = full * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * full)

    data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: full, height: full,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rect = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: CGFloat(size), height: CGFloat(size))
        ctx.saveGState()
        ctx.addPath(shape.path(in: rect))
        ctx.clip()
        subject.draw(in: ctx, rect: rect)
        ctx.restoreGState()
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: full, height: full, mipmapped: false)
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .managed
    let texture = device.makeTexture(descriptor: descriptor)!
    data.withUnsafeBytes { raw in
        texture.replace(region: MTLRegionMake2D(0, 0, full, full), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
    }
    return texture
}

struct PreviewUniforms {
    var size: SIMD2<Float>
    var tilt: SIMD2<Float>
    var flow: SIMD2<Float>
    var time: Float
    var seed: Float
    var pad: Float
    var paramCount: Int32
    var functionIndex: Int32
}

// MARK: - レンダラ

final class PreviewRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

    init(libraryURL: URL) throws {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(URL: libraryURL)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "preview_render")!)
    }

    func render(source: MTLTexture, size: Int, pad: Int, uniforms: inout PreviewUniforms,
                params: [Float]) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .managed
        let output = device.makeTexture(descriptor: descriptor)!

        let paramBuffer = device.makeBuffer(bytes: params.isEmpty ? [Float(0)] : params,
                                            length: max(params.count, 1) * 4)!

        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.setBuffer(paramBuffer, offset: 0, index: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                threadsPerThreadgroup: group)
        encoder.endEncoding()

        let blit = buffer.makeBlitCommandEncoder()!
        blit.synchronize(resource: output)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes { raw in
            output.getBytes(raw.baseAddress!, bytesPerRow: size * 4,
                            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }
}

// MARK: - コンタクトシート

/// 行＝個体、列＝傾き。台紙の色は本番のシール帳に近いものを敷く。
func writeSheet(path: String, tiles: [[[UInt8]]], tile: Int, labels: [String], title: String) {
    let cols = tiles.first?.count ?? 0
    let rows = tiles.count
    guard cols > 0, rows > 0 else { return }
    let gap = 10
    let header = 26
    let labelW = 150
    let width = labelW + cols * (tile + gap) + gap
    let height = header + rows * (tile + gap) + gap

    let bytesPerRow = width * 4
    var canvas = [UInt8](repeating: 0, count: bytesPerRow * height)
    canvas.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (r, row) in tiles.enumerated() {
            for (c, pixels) in row.enumerated() {
                var copy = pixels
                let provider = CGDataProvider(data: Data(bytes: &copy, count: copy.count) as CFData)!
                guard let image = CGImage(width: tile, height: tile, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: tile * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent) else { continue }
                let x = labelW + c * (tile + gap) + gap
                let y = height - header - (r + 1) * (tile + gap)
                ctx.draw(image, in: CGRect(x: x, y: y, width: tile, height: tile))
            }
        }

        // ラベル
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx
        NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]).draw(at: NSPoint(x: 10, y: CGFloat(height - header + 5)))
        for (r, label) in labels.enumerated() where r < rows {
            let y = height - header - (r + 1) * (tile + gap) + tile / 2
            NSAttributedString(string: label, attributes: attrs)
                .draw(in: NSRect(x: 8, y: CGFloat(y - 30), width: CGFloat(labelW - 12), height: 60))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    var copy = canvas
    let provider = CGDataProvider(data: Data(bytes: &copy, count: copy.count) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try? data.write(to: URL(fileURLWithPath: path))
    FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
}

// MARK: - 実行

let args = CommandLine.arguments
func argValue(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let libraryPath = argValue("-library", "preview.metallib")
let catalogPath = argValue("-catalog", "StickerLab/Catalog/Effects.json")
let outDir = argValue("-out", "out")
let tile = Int(argValue("-tile", "220"))!
let subject = PreviewSubject(rawValue: argValue("-subject", "paleFlat")) ?? .paleFlat
let shape = PreviewShape(rawValue: argValue("-shape", "squircle")) ?? .squircle
let onlyEffect = argValue("-effect", "")
let time = Float(argValue("-time", "3.0"))!
let variantCount = Int(argValue("-variants", "4"))!
let baseSeed = UInt64(argValue("-seed", "20260911"))!

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let catalog = try JSONDecoder().decode(
    [EffectDefinition].self, from: Data(contentsOf: URL(fileURLWithPath: catalogPath)))
let renderer = try PreviewRenderer(libraryURL: URL(fileURLWithPath: libraryPath))

let pad = max(16, Int(Double(tile) * 0.26))
let source = makeSourceTexture(device: renderer.device, size: tile, pad: pad,
                               subject: subject, shape: shape)

// 傾きの見本。静止・軽い傾き・強い傾きを一列に並べて、動きの幅を一目で見る。
let tilts: [(String, SIMD2<Float>, SIMD2<Float>)] = [
    ("0,0",      SIMD2(0, 0),        SIMD2(0, 0)),
    ("-0.5,0",   SIMD2(-0.5, 0),     SIMD2(-1.2, 0)),
    ("0.5,0",    SIMD2(0.5, 0),      SIMD2(1.2, 0)),
    ("0,-0.6",   SIMD2(0, -0.6),     SIMD2(0, -1.4)),
    ("0,0.6",    SIMD2(0, 0.6),      SIMD2(0, 1.4)),
    ("0.7,0.7",  SIMD2(0.7, 0.7),    SIMD2(0.5, 0.5))
]

let functionIndex: [String: Int32] = ["fx_flatFoil": 0, "fx_puffyGloss": 1, "fx_waterCapsule": 2]
/// 形だけを見たいときの切り替え。陰影の調整と形の調整を混ぜないために分けている。
let debugDome = args.contains("-debug")

for effect in catalog where onlyEffect.isEmpty || effect.id == onlyEffect {
    guard var index = functionIndex[effect.shaderFunction] else { continue }
    if debugDome { index = 3 }
    var rng = SeededGenerator(seed: baseSeed)
    var rows: [[[UInt8]]] = []
    var labels: [String] = []

    for v in 0..<variantCount {
        let instance = StickerFactory.make(effect: effect, subjectID: subject.rawValue,
                                           shapeID: shape.rawValue, using: &rng)
        let params = effect.paramSchema.map { instance.renderParams[$0.name] ?? $0.min }
        var row: [[UInt8]] = []
        for (_, tilt, flow) in tilts {
            var uniforms = PreviewUniforms(
                size: SIMD2(Float(tile), Float(tile)), tilt: tilt, flow: flow,
                time: time, seed: instance.renderSeed, pad: Float(pad),
                paramCount: Int32(params.count), functionIndex: index)
            row.append(renderer.render(source: source, size: tile, pad: pad,
                                       uniforms: &uniforms, params: params))
        }
        rows.append(row)

        let grade = effect.grades.first { $0.id == instance.grade }?.displayName ?? instance.grade
        let detail = effect.paramSchema.prefix(4)
            .map { "\($0.name.prefix(9))=\(String(format: "%.2f", instance.renderParams[$0.name] ?? 0))" }
            .joined(separator: "\n")
        labels.append("#\(v) \(grade)\n\(detail)")
    }

    let safe = effect.id.replacingOccurrences(of: ".", with: "_")
    writeSheet(path: "\(outDir)/\(safe)_\(subject.rawValue)_\(shape.rawValue)\(debugDome ? "_dome" : "").png",
               tiles: rows, tile: tile, labels: labels,
               title: "\(effect.displayName)  [\(effect.id)]  \(subject.rawValue)/\(shape.rawValue)  tilt: " +
                      tilts.map { $0.0 }.joined(separator: "  |  "))
}
