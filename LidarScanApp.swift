import SwiftUI
import RealityKit
import UIKit

@main
struct LidarScanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            ScanScreen()
                .tabItem { Label("Scan", systemImage: "cube.transparent") }
            ObjectCaptureScreen()
                .tabItem { Label("3D-print", systemImage: "printer") }
            RoomScreen()
                .tabItem { Label("Kamer", systemImage: "square.split.bottomrightquarter") }
            MeasureScreen()
                .tabItem { Label("Meten", systemImage: "ruler") }
            FilesScreen()
                .tabItem { Label("Bestanden", systemImage: "folder") }
        }
        // Scherm blijft aan tijdens het scannen
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

/// Wrapper om een bestaande ARView in SwiftUI te tonen.
struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

enum Storage {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    static func url(_ name: String) -> URL {
        documents.appendingPathComponent(name)
    }
}

/// Kleine knopstijl die overal hetzelfde oogt.
struct PillButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(tint, in: Capsule())
                .foregroundStyle(.white)
        }
    }
}
