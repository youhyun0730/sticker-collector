import SwiftUI

/// シール1枚の描画。
///
/// 被写体 → 形状マスク → 加工シェーダー、の順で合成する。
/// 加工は layerEffect で被写体の上に掛かるため、切り抜き形状が任意でも成立する。
struct StickerView: View {
    let instance: StickerInstance
    @EnvironmentObject private var engine: MotionEngine

    /// 傾き追従を無効化したい場面（一覧のサムネイルなど）で固定値を与える。
    var fixedTilt: SIMD2<Float>?

    var body: some View {
        let resolved = EffectCatalog.shared.resolveForRendering(
            id: instance.effectID,
            fallbackHint: instance.fallbackEffectID
        )
        let tilt = fixedTilt ?? engine.tilt(for: instance.id)
        let flow = fixedTilt == nil ? engine.flow(for: instance.id) : .zero

        GeometryReader { proxy in
            let size = proxy.size
            SubjectLibrary.view(subjectID: instance.subjectID)
                .frame(width: size.width, height: size.height)
                .mask(StickerShape.shape(id: instance.shapeID).fill(style: FillStyle(eoFill: false, antialiased: true)))
                .layerEffect(
                    StickerShader.make(
                        definition: resolved.definition,
                        instance: instance,
                        size: size,
                        tilt: tilt,
                        flow: flow,
                        time: engine.time
                    ),
                    maxSampleOffset: StickerShader.maxSampleOffset(for: size)
                )
                // 台紙からわずかに浮かせる。材質差の知覚は影の有無にも依存する。
                .shadow(color: .black.opacity(0.28), radius: size.width * 0.035, x: 0, y: size.width * 0.018)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            engine.register(instance: instance, material: resolved.definition.material)
        }
        .onDisappear {
            engine.unregister(instance.id)
        }
    }
}

/// 切り抜き形状。フェーズ1で Vision のマスクに置き換わる箇所。
enum StickerShape {
    static let allIDs = ["circle", "roundedRect", "star", "blob", "squircle"]

    static func shape(id: String) -> AnyShape {
        switch id {
        case "roundedRect": return AnyShape(RelativeRoundedRect(fraction: 0.18))
        case "star":        return AnyShape(StarShape(points: 5, innerRatio: 0.46))
        case "blob":        return AnyShape(BlobShape())
        case "squircle":    return AnyShape(RelativeRoundedRect(fraction: 0.44))
        default:            return AnyShape(Circle())
        }
    }

    static func displayName(id: String) -> String {
        switch id {
        case "roundedRect": return "角丸"
        case "star":        return "星"
        case "blob":        return "自由形"
        case "squircle":    return "スクワークル"
        default:            return "円"
        }
    }
}

/// 角丸の比率を辺の長さに対して指定する。表示サイズが変わっても見た目の丸みが保たれる。
struct RelativeRoundedRect: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * fraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

struct StarShape: Shape {
    var points: Int = 5
    var innerRatio: CGFloat = 0.46

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 * 0.98
        let inner = outer * innerRatio
        let step = CGFloat.pi / CGFloat(points)
        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = step * CGFloat(i) - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// 手描き切り抜きに近い、角の無い不定形。ぷっくりの法線推定を曲率の変化で試すために置く。
struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2 * 0.95
        let lobes: [CGFloat] = [1.0, 0.86, 1.04, 0.9, 1.08, 0.88]
        let count = 72
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count) * 2 * .pi
            var radius = base
            for (index, weight) in lobes.enumerated() {
                radius += base * 0.055 * (weight - 1.0) * cos(t * CGFloat(index + 2))
            }
            radius += base * 0.06 * sin(t * 3 + 0.7)
            let point = CGPoint(x: center.x + cos(t) * radius, y: center.y + sin(t) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
