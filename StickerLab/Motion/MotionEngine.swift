import Combine
import CoreMotion
import QuartzCore
import SwiftUI

/// 傾きの供給と、材質ごとの追従計算をまとめて行う。
///
/// 個体ごとにばね1つを持ち、表示フレームごとに一括で積分する。
/// シールの枚数が増えてもタイマーは1本しか回らない。
@MainActor
final class MotionEngine: NSObject, ObservableObject {

    /// 傾きの供給源。実機ではジャイロ、シミュレータでは指またはデモ回転。
    enum Source: String, CaseIterable, Identifiable {
        case gyro = "ジャイロ"
        case drag = "ドラッグ"
        case orbit = "自動回転"
        var id: String { rawValue }
    }

    /// 表示フレームごとに進むカウンタ。ビューはこれを購読して再描画する。
    @Published private(set) var frame: Int = 0
    @Published var source: Source = .gyro
    /// 追従の有効/無効。止めたときとの差を見るために切り替えられるようにしておく。
    @Published var isFollowing: Bool = true
    @Published private(set) var smoothedFPS: Double = 0
    @Published private(set) var isGyroAvailable: Bool = false

    /// 経過時間。シェーダーの time 引数に渡す。
    private(set) var time: Double = 0
    /// 平滑化前の生の傾き。-1...1。
    private(set) var rawTilt: SIMD2<Float> = .zero

    private let motionManager = CMMotionManager()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var startTimestamp: CFTimeInterval = 0
    private var referenceAttitude: CMAttitude?
    private var followers: [UUID: Follower] = [:]
    private var dragTilt: SIMD2<Float> = .zero

    /// 傾きの正規化幅。これ以上倒しても飽和する。おおよそ 34 度。
    private let tiltRange: Float = 0.6

    // MARK: - ライフサイクル

    func start() {
        isGyroAvailable = motionManager.isDeviceMotionAvailable
        if !isGyroAvailable && source == .gyro {
            // シミュレータではジャイロが無い。まず自動回転で動きを見せ、
            // 細かく確かめたいときに指で傾けられるようにしておく。
            source = .orbit
        }
        startMotionUpdates()

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        motionManager.stopDeviceMotionUpdates()
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates()
    }

    /// 現在の持ち方を「正面」とみなす。
    /// 端末を寝かせて見るか立てて見るかで基準が変わるため、任意に取り直せる必要がある。
    func recalibrate() {
        referenceAttitude = motionManager.deviceMotion?.attitude.copy() as? CMAttitude
    }

    // MARK: - フレーム更新

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        if startTimestamp == 0 { startTimestamp = now }
        let dt = lastTimestamp == 0 ? 1.0 / 60.0 : min(now - lastTimestamp, 1.0 / 20.0)
        lastTimestamp = now
        time = now - startTimestamp

        let instantFPS = dt > 0 ? 1.0 / dt : 0
        smoothedFPS = smoothedFPS == 0 ? instantFPS : smoothedFPS * 0.9 + instantFPS * 0.1

        rawTilt = currentTilt()

        let target = isFollowing ? rawTilt : .zero
        for key in followers.keys {
            followers[key]?.update(target: target, dt: Float(dt))
        }

        frame &+= 1
    }

    private func currentTilt() -> SIMD2<Float> {
        switch source {
        case .drag:
            return dragTilt
        case .orbit:
            // 検証用のデモ回転。手を使わずに全枚数の挙動を見比べるために使う。
            let t = Float(time)
            return SIMD2(sin(t * 0.9) * 0.75, cos(t * 0.62) * 0.6)
        case .gyro:
            guard let motion = motionManager.deviceMotion else { return .zero }
            let attitude = motion.attitude.copy() as! CMAttitude
            if let reference = referenceAttitude {
                attitude.multiply(byInverseOf: reference)
            } else {
                referenceAttitude = motion.attitude.copy() as? CMAttitude
                return .zero
            }
            let x = Float(attitude.roll) / tiltRange
            let y = Float(attitude.pitch) / tiltRange
            return SIMD2(max(-1, min(1, x)), max(-1, min(1, y)))
        }
    }

    func setDragTilt(_ tilt: SIMD2<Float>) {
        dragTilt = SIMD2(max(-1, min(1, tilt.x)), max(-1, min(1, tilt.y)))
    }

    // MARK: - 個体ごとの追従

    /// 個体の材質に応じたばねを登録する。
    ///
    /// 水入りは `viscosity` を読んで硬さと減衰を変える。
    /// 同じ水入りでも粘度の乱数が違えば揺れ方が変わり、個体差が動きにも現れる。
    func register(instance: StickerInstance, material: EffectDefinition.MaterialClass) {
        if followers[instance.id] != nil { return }
        let viscosity = instance.renderParams["viscosity"] ?? 0.6
        followers[instance.id] = Follower(material: material, viscosity: viscosity, initial: rawTilt)
    }

    func unregister(_ id: UUID) {
        followers.removeValue(forKey: id)
    }

    /// 個体に適用すべき傾き。未登録なら生の値を返す。
    func tilt(for id: UUID) -> SIMD2<Float> {
        followers[id]?.value ?? rawTilt
    }

    /// 個体の傾きが毎秒どれだけ動いているか。
    ///
    /// シェーダーは状態を持てないため、「今まさに動かされている」ことは
    /// この値でしか伝えられない。箔の一閃と液面の波立ちがこれを読む。
    func flow(for id: UUID) -> SIMD2<Float> {
        followers[id]?.velocity ?? .zero
    }

    var registeredCount: Int { followers.count }

    // MARK: - ばね

    /// 材質ごとの追従特性。
    ///
    /// フラットは即応、ぷっくりはわずかに遅れ、水入りは遅れて揺れ戻す。
    /// 3材質の差を「見た目」だけでなく「動きの時定数」でも作るのが狙い。
    private final class Follower {
        var value: SIMD2<Float>
        var velocity: SIMD2<Float> = .zero
        let stiffness: Float
        let damping: Float

        init(material: EffectDefinition.MaterialClass, viscosity: Float, initial: SIMD2<Float>) {
            value = initial
            switch material {
            case .flat:
                stiffness = 900
                damping = 60
            case .puffy:
                stiffness = 220
                damping = 26
            case .liquid:
                let v = max(0, min(1, viscosity))
                // 粘度が低いほど軽く速く、大きく行き過ぎて戻る。
                stiffness = 95 - 55 * v
                damping = 3.5 + 9.5 * v
            }
        }

        func update(target: SIMD2<Float>, dt: Float) {
            // 大きな dt でばねが発散しないよう、固定刻みで分割する。
            var remaining = dt
            let maxStep: Float = 1.0 / 120.0
            while remaining > 0 {
                let h = min(remaining, maxStep)
                let acceleration = (target - value) * stiffness - velocity * damping
                velocity += acceleration * h
                value += velocity * h
                remaining -= h
            }
        }
    }
}
