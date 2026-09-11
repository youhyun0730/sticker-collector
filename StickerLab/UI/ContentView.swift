import SwiftUI

struct ContentView: View {
    @StateObject private var engine = MotionEngine()
    @StateObject private var store = LabStore()
    @State private var selectedTab: Int = LabLaunchOptions.initialTab

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                MaterialCompareView(store: store)
                    .navigationTitle("材質")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tag(0)
            .tabItem { Label("材質", systemImage: "square.3.layers.3d") }

            NavigationStack {
                VariantView(store: store)
                    .navigationTitle("個体差")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tag(1)
            .tabItem { Label("個体差", systemImage: "dice") }

            NavigationStack {
                StressView(store: store)
                    .navigationTitle("描画負荷")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tag(2)
            .tabItem { Label("負荷", systemImage: "speedometer") }

            NavigationStack {
                DataIntegrityView(store: store)
                    .navigationTitle("データ")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tag(3)
            .tabItem { Label("データ", systemImage: "shippingbox") }
        }
        .environmentObject(engine)
        .preferredColorScheme(.dark)
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }
}

#Preview {
    ContentView()
}
