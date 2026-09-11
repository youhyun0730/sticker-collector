import SwiftUI

/// 被写体。本番ではカメラロールの画像だが、フェーズ0では加工の効き方を
/// 比較するために性質の異なる素材を手続き的に用意する。
///
/// 特に「明るく平坦な素材」はホロ箔が乗りにくく、加工が最も苦しくなる条件のため、
/// 検証対象として必ず含める。
enum SubjectLibrary {

    struct Subject: Identifiable {
        let id: String
        let displayName: String
    }

    static let builtins: [Subject] = [
        Subject(id: "sunset", displayName: "夕景（暗部あり）"),
        Subject(id: "portrait", displayName: "人物風（中間調）"),
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

private struct SunsetSubject: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.08, blue: 0.26),
                         Color(red: 0.56, green: 0.20, blue: 0.35),
                         Color(red: 0.96, green: 0.56, blue: 0.28)],
                startPoint: .top, endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 1.0, green: 0.86, blue: 0.55))
                .frame(width: 60, height: 60)
                .offset(y: 26)
                .blur(radius: 2)
            Ellipse()
                .fill(Color(red: 0.06, green: 0.05, blue: 0.13))
                .frame(width: 260, height: 70)
                .offset(y: 92)
        }
    }
}

private struct PortraitSubject: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.86, green: 0.80, blue: 0.74), Color(red: 0.42, green: 0.38, blue: 0.44)],
                center: .init(x: 0.42, y: 0.34), startRadius: 8, endRadius: 180
            )
            Circle()
                .fill(Color(red: 0.93, green: 0.82, blue: 0.72))
                .frame(width: 92, height: 92)
                .offset(y: -16)
            Capsule()
                .fill(Color(red: 0.28, green: 0.30, blue: 0.40))
                .frame(width: 140, height: 120)
                .offset(y: 96)
        }
    }
}

private struct PaleFlatSubject: View {
    var body: some View {
        ZStack {
            Color(red: 0.93, green: 0.93, blue: 0.94)
            LinearGradient(
                colors: [Color.white.opacity(0.9), Color(red: 0.87, green: 0.88, blue: 0.90)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .stroke(Color(red: 0.78, green: 0.79, blue: 0.82), lineWidth: 6)
                .frame(width: 96, height: 96)
        }
    }
}

private struct GraphicSubject: View {
    var body: some View {
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
                    .frame(width: 46, height: 220)
                    .rotationEffect(.degrees(Double(index) * 34 - 60))
                    .offset(x: CGFloat(index) * 26 - 52)
            }
        }
    }
}
