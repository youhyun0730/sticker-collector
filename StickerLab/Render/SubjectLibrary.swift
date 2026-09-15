import SwiftUI

/// 被写体。本番ではカメラロールの画像だが、フェーズ0では加工の効き方を
/// 比較するために性質の異なる素材を手続き的に用意する。
///
/// 特に「明るく平坦な素材」はホロ箔が乗りにくく、加工が最も苦しくなる条件のため、
/// 検証対象として必ず含める。
///
/// **寸法はすべて枠に対する比率で書く。** 絶対ポイントで描くと、同じ個体が
/// 一覧の小さな枠と拡大表示とで別の絵になり、加工の評価ができなくなる。
/// また、絵として「物」に見える形（丸や台座）は置かない。加工の筋や光が
/// 被写体の輪郭と見分けられなくなるため。見たいのは階調と彩度の条件だけ。
enum SubjectLibrary {

    struct Subject: Identifiable {
        let id: String
        let displayName: String
    }

    static let builtins: [Subject] = [
        Subject(id: "sunset", displayName: "夕景（暗部あり）"),
        Subject(id: "portrait", displayName: "中間調（肌色系）"),
        Subject(id: "paleFlat", displayName: "淡い平坦（最難条件）"),
        Subject(id: "graphic", displayName: "高彩度グラフィック")
    ]

    /// ユーザーが選んだ写真。プロセス内で共有する。
    static var userImage: Image?

    @ViewBuilder
    static func view(subjectID: String) -> some View {
        switch subjectID {
        case "user":
            if let image = userImage {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                SunsetSubject()
            }
        case "portrait":  PortraitSubject()
        case "paleFlat":  PaleFlatSubject()
        case "graphic":   GraphicSubject()
        default:          SunsetSubject()
        }
    }

    static func displayName(subjectID: String) -> String {
        if subjectID == "user" { return "選択した写真" }
        return builtins.first { $0.id == subjectID }?.displayName ?? subjectID
    }
}

/// 暗部から明部まで一気に振れる縦のグラデーション。
/// 箔とハイライトが「暗いところ」と「白飛び寸前のところ」の両方でどう出るかを一枚で見る。
private struct SunsetSubject: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.06, blue: 0.20),
                             Color(red: 0.32, green: 0.13, blue: 0.33),
                             Color(red: 0.78, green: 0.33, blue: 0.32),
                             Color(red: 0.99, green: 0.74, blue: 0.42)],
                    startPoint: .top, endPoint: .bottom
                )
                // 明部側にさらに明るい広がりを足す。輪郭を持たせないため、
                // 枠いっぱいまで滑らかに落ちるだけの薄い層にする。
                RadialGradient(
                    colors: [Color(red: 1.0, green: 0.92, blue: 0.72).opacity(0.55), .clear],
                    center: UnitPoint(x: 0.5, y: 0.78), startRadius: 0, endRadius: side * 0.95
                )
            }
        }
    }
}

/// 肌に近い中間調。加工がいちばん自然に見えるべき条件。
private struct PortraitSubject: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.90, green: 0.83, blue: 0.76),
                             Color(red: 0.62, green: 0.53, blue: 0.52),
                             Color(red: 0.36, green: 0.33, blue: 0.40)],
                    center: UnitPoint(x: 0.38, y: 0.30), startRadius: 0, endRadius: side * 1.05
                )
                LinearGradient(
                    colors: [.clear, Color(red: 0.20, green: 0.17, blue: 0.24).opacity(0.45)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }
}

/// 淡く平坦。加算で虹を乗せる作りが白く飛んで消える、いちばん苦しい条件。
///
/// 細い格子を薄く敷いてある。縁で像が圧縮される（屈折）かどうかは、
/// 直線が曲がるところでしか読み取れないため、判定用の目盛りとして置く。
private struct PaleFlatSubject: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.96, blue: 0.97),
                             Color(red: 0.86, green: 0.87, blue: 0.90)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Canvas { context, size in
                    let step = side / 9
                    let line = max(0.5, side * 0.006)
                    var path = Path()
                    var x = step / 2
                    while x < size.width {
                        path.addRect(CGRect(x: x, y: 0, width: line, height: size.height))
                        x += step
                    }
                    var y = step / 2
                    while y < size.height {
                        path.addRect(CGRect(x: 0, y: y, width: size.width, height: line))
                        y += step
                    }
                    context.fill(path, with: .color(Color(red: 0.74, green: 0.75, blue: 0.79).opacity(0.55)))
                }
            }
        }
    }
}

/// 高彩度。すでに色が付いている上に箔を乗せると濁らないか、を見る。
private struct GraphicSubject: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.10)
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(
                            [Color(red: 1.0, green: 0.30, blue: 0.45),
                             Color(red: 0.25, green: 0.85, blue: 0.95),
                             Color(red: 1.0, green: 0.82, blue: 0.25),
                             Color(red: 0.55, green: 0.40, blue: 1.0),
                             Color(red: 0.30, green: 0.95, blue: 0.55)][index]
                        )
                        .frame(width: side * 0.19, height: side * 1.8)
                        .rotationEffect(.degrees(Double(index) * 34 - 60))
                        .offset(x: side * (CGFloat(index) * 0.105 - 0.21))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
