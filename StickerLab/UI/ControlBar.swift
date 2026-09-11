import PhotosUI
import SwiftUI

/// 検証条件の切り替え。被写体・形状・傾きの供給源を一箇所にまとめる。
struct ControlBar: View {
    @EnvironmentObject private var engine: MotionEngine
    @ObservedObject var store: LabStore
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("傾き", selection: $engine.source) {
                    ForEach(MotionEngine.Source.allCases) { source in
                        Text(source.rawValue)
                            .tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(false)

                Button {
                    engine.recalibrate()
                } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.bordered)
                .disabled(engine.source != .gyro)
            }

            if engine.source == .gyro && !engine.isGyroAvailable {
                Label("この端末ではジャイロを取得できません。ドラッグか自動回転で確認してください。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Picker("被写体", selection: $store.subjectID) {
                    ForEach(SubjectLibrary.builtins) { subject in
                        Text(subject.displayName).tag(subject.id)
                    }
                    if SubjectLibrary.userImage != nil {
                        Text("選択した写真").tag("user")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            Picker("形状", selection: $store.shapeID) {
                ForEach(StickerShape.allIDs, id: \.self) { id in
                    Text(StickerShape.displayName(id: id)).tag(id)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Toggle("傾きに追従", isOn: $engine.isFollowing)
                    .toggleStyle(.switch)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.0f fps", engine.smoothedFPS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(engine.smoothedFPS < 50 ? .orange : .secondary)
                Text(String(format: "傾き %.2f / %.2f", engine.rawTilt.x, engine.rawTilt.y))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    SubjectLibrary.userImage = Image(uiImage: uiImage)
                    store.subjectID = "user"
                }
            }
        }
    }
}
