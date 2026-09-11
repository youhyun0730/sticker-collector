import Foundation

/// シール個体（SPEC 6.2）。
///
/// フェーズ0では切り抜き（Vision）と永続化は範囲外のため、
/// 被写体は `subjectID`、形状は `shapeID` という参照だけを持つ。
/// 加工エンジンの検証に必要な項目はすべて本番と同じ構造で保持する。
struct StickerInstance: Codable, Identifiable, Hashable {
    /// 個体の同一性。交換されても変わらない。
    let id: UUID
    /// 被写体画像への参照。本番では端末内の画像実体を指す。
    let subjectID: String
    /// 切り抜き形状への参照。本番ではマスクまたはパス。
    let shapeID: String

    let effectID: String
    let effectVersion: Int
    /// 個体が知っている代替加工 ID。受信側が effectID を知らないときに使う。
    let fallbackEffectID: String?

    /// 抽選で決まった加工グレードの識別子。
    let grade: String
    /// 乱数で固定された加工パラメータ群。生成時に一度だけ確定し、以後変更されない。
    let renderParams: [String: Float]

    let schemaVersion: Int
    let createdAt: Date

    static let currentSchemaVersion = 1

    /// 個体固有の描画シード。
    ///
    /// UUID から決定論的に導出するため、交換して他人の端末へ渡っても同じ値になる。
    /// パラメータが偶然近い個体どうしでも、粒の配置が重ならないようにするために使う。
    var renderSeed: Float {
        var hash: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        // 0..<1024 の範囲に落とす。float32 で正確に表現できる粒度に留める。
        return Float(hash % 1_048_576) / 1024.0
    }
}
