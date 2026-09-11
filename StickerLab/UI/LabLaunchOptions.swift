import Foundation

/// 起動引数で初期状態を指定する。
///
/// 検証は「同じ画面を同じ条件で撮って見比べる」作業が中心になるため、
/// スクリーンショットの取得を手作業に依存させないための入口を用意する。
///
///   xcrun simctl launch <device> com.stickerlab.phase0 -startTab 2 -focusMaterial 1
enum LabLaunchOptions {
    /// 起動時に開くタブ。0=材質 1=個体差 2=負荷 3=データ
    static var initialTab: Int {
        clamp(integer(forKey: "startTab") ?? 0, 0, 3)
    }

    /// 材質タブで拡大表示する加工の番号。
    static var focusedMaterial: Int {
        clamp(integer(forKey: "focusMaterial") ?? 2, 0, 2)
    }

    /// コマンドラインから渡された値は文字列として入るため、数値へ変換して読む。
    private static func integer(forKey key: String) -> Int? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
