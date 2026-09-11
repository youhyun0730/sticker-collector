import SwiftUI

/// 検証項目3：見開きに多数のシールを並べ、全てを傾きに追従させたときのフレームレート。
///
/// SPEC 7 の「描画負荷」に対応する。枚数を変えて落ちはじめる点を探す。
struct StressView: View {
    @EnvironmentObject private var engine: MotionEngine
    @ObservedObject var store: LabStore
    @State private var columnCount: Int = 3

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("枚数")
                    .font(.caption)
                Picker("枚数", selection: $store.stressCount) {
                    ForEach([6, 12, 24, 40], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)

                Picker("列", selection: $columnCount) {
                    ForEach([2, 3, 4], id: \.self) { count in
                        Text("\(count)列").tag(count)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack(spacing: 14) {
                Label(String(format: "%.0f fps", engine.smoothedFPS), systemImage: "speedometer")
                    .font(.callout.monospacedDigit().bold())
                    .foregroundStyle(engine.smoothedFPS < 50 ? .orange : .green)
                Text("追従中 \(engine.registeredCount) 枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("追従", isOn: $engine.isFollowing)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Picker("傾き", selection: $engine.source) {
                    ForEach(MotionEngine.Source.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.menu)
            }

            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount),
                    spacing: 8
                ) {
                    ForEach(store.stressSamples) { instance in
                        StickerView(instance: instance)
                    }
                }
                .tiltDraggable(engine: engine, enabled: engine.source == .drag)
                .padding(.bottom, 12)
            }

            Text("実機での計測が前提です。シミュレータの数値は参考になりません。自動回転にすると、手を使わずに全枚数が動き続ける状態で計測できます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
