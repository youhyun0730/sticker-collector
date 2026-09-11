import SwiftUI

/// ジャイロが無い環境（シミュレータ）で、指のドラッグを傾きの代わりにする。
///
/// 実機検証の前段として、シェーダーの応答そのものを机上で確認するために用意する。
/// 離しても傾きを保持するので、水入りの揺れ戻りが収まる様子を見られる。
struct TiltDragModifier: ViewModifier {
    let engine: MotionEngine
    let enabled: Bool
    @State private var base: SIMD2<Float> = .zero

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            engine.setDragTilt(base + delta(value.translation))
                        }
                        .onEnded { value in
                            let next = base + delta(value.translation)
                            base = SIMD2(max(-1, min(1, next.x)), max(-1, min(1, next.y)))
                            engine.setDragTilt(base)
                        }
                )
                .onTapGesture(count: 2) {
                    base = .zero
                    engine.setDragTilt(.zero)
                }
        } else {
            content
        }
    }

    private func delta(_ translation: CGSize) -> SIMD2<Float> {
        SIMD2(Float(translation.width / 130), Float(translation.height / 130))
    }
}

extension View {
    func tiltDraggable(engine: MotionEngine, enabled: Bool) -> some View {
        modifier(TiltDragModifier(engine: engine, enabled: enabled))
    }
}
