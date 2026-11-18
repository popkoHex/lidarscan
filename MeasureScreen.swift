import SwiftUI
import RealityKit
import ARKit

/// Meten met LiDAR: punten plaatsen met het kruisje, afstanden, hoogteverschil en oppervlakte.
final class MeasureController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero)
    @Published var points: [SIMD3<Float>] = []
    @Published var liveDistance: Float? = nil
    @Published var message = ""

    private let root = AnchorEntity(world: .zero)
    private var lastLive: TimeInterval = 0

    override init() {
        super.init()
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        arView.scene.addAnchor(root)
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arView.session.run(config)
    }

    func pause() { arView.session.pause() }

    private func hitAtCenter() -> SIMD3<Float>? {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let r = arView.raycast(from: c, allowing: .estimatedPlane, alignment: .any).first else {
            return nil
        }
        let p = r.worldTransform.columns.3
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    func addPoint() {
        guard let p = hitAtCenter() else {
            message = "Geen oppervlak gevonden. Beweeg de telefoon iets."
            return
        }
        message = ""
        points.append(p)
        rebuild()
        Haptics.tap()
    }

    /// Slaat de metingen op als tekstbestand.
    func save() {
        guard points.count > 1 else {
            message = "Plaats eerst minstens 2 punten."
            return
        }
        var lines = ["METING – \(Storage.stamp())", ""]
        for (i, d) in segments.enumerated() {
            lines.append(String(format: "Stuk %d: %.1f cm", i + 1, d * 100))
        }
        lines.append(String(format: "Totaal: %.1f cm", total * 100))
        if let h = heightDiff { lines.append(String(format: "Hoogteverschil 1e→laatste: %.1f cm", h * 100)) }
        if let a = area { lines.append(String(format: "Oppervlakte (gesloten vorm): %.3f m²", a)) }
        let name = "Meting \(Storage.stamp()).txt"
        do {
            try lines.joined(separator: "\n").write(to: Storage.url(name), atomically: true, encoding: .utf8)
            message = "Opgeslagen: \(name)"
            Haptics.notify(.success)
        } catch {
            message = "Opslaan mislukt: \(error.localizedDescription)"
        }
    }

    func undo() {
        guard !points.isEmpty else { return }
        points.removeLast()
        rebuild()
    }

    func clear() {
        points.removeAll()
        rebuild()
    }

    // MARK: Berekeningen

    var segments: [Float] {
        guard points.count > 1 else { return [] }
        return (1..<points.count).map { simd_distance(points[$0 - 1], points[$0]) }
    }

    var total: Float { segments.reduce(0, +) }

    /// Hoogteverschil tussen eerste en laatste punt.
    var heightDiff: Float? {
        guard let a = points.first, let b = points.last, points.count > 1 else { return nil }
        return abs(b.y - a.y)
    }

    /// Oppervlakte van de (gesloten) veelhoek door alle punten (Newell-methode, werkt ook op schuine vlakken).
    var area: Float? {
        guard points.count >= 3 else { return nil }
        var n = SIMD3<Float>(repeating: 0)
        for i in 0..<points.count {
            n += simd_cross(points[i], points[(i + 1) % points.count])
        }
        return simd_length(n) / 2
    }

    // MARK: 3D-weergave

    private func rebuild() {
        for child in Array(root.children) { child.removeFromParent() }
        let dot = MeshResource.generateSphere(radius: 0.006)
        let dotMat = SimpleMaterial(color: .systemYellow, isMetallic: false)
        let lineMat = SimpleMaterial(color: .white, isMetallic: false)
        for p in points {
            let e = ModelEntity(mesh: dot, materials: [dotMat])
            e.position = p
            root.addChild(e)
        }
        guard points.count > 1 else { return }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let len = simd_distance(a, b)
            guard len > 0.0005 else { continue }
            let line = ModelEntity(mesh: .generateBox(size: [0.0025, 0.0025, len]), materials: [lineMat])
            let mid = (a + b) / 2
            let dir = simd_normalize(b - a)
            let up: SIMD3<Float> = abs(dir.y) > 0.99 ? [1, 0, 0] : [0, 1, 0]
            root.addChild(line)
            line.look(at: b, from: mid, upVector: up, relativeTo: nil)
        }
    }

    // MARK: ARSessionDelegate – live afstand tot het kruisje

    func session(_ session: ARSession, didFailWithError error: Error) {
        message = "AR-fout: \(error.localizedDescription)"
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastLive > 0.1 else { return }
        lastLive = frame.timestamp
        guard let last = points.last, let p = hitAtCenter() else {
            if liveDistance != nil { liveDistance = nil }
            return
        }
        liveDistance = simd_distance(last, p)
    }
}

struct MeasureScreen: View {
    @StateObject private var c = MeasureController()

    private func fmt(_ m: Float) -> String {
        m < 1 ? String(format: "%.1f cm", m * 100) : String(format: "%.3f m", m)
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: c.arView).ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 34, weight: .thin))
                .foregroundStyle(.white)
                .shadow(radius: 2)

            if let live = c.liveDistance {
                Text(fmt(live))
                    .font(.headline.monospacedDigit())
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: 40)
            }

            VStack {
                VStack(alignment: .leading, spacing: 4) {
                    if c.points.isEmpty {
                        Text("Richt het kruisje en tik op ‘Punt’.")
                    }
                    ForEach(Array(c.segments.enumerated()), id: \.offset) { i, d in
                        Text("Stuk \(i + 1): \(fmt(d))")
                    }
                    if c.segments.count > 1 {
                        Text("Totaal: \(fmt(c.total))").bold()
                    }
                    if let h = c.heightDiff {
                        Text("Hoogteverschil 1e→laatste: \(fmt(h))")
                    }
                    if let a = c.area {
                        Text(String(format: "Oppervlakte (gesloten vorm): %.2f m²", a)).bold()
                    }
                    if !c.message.isEmpty {
                        Text(c.message).foregroundStyle(.orange)
                    }
                }
                .font(.subheadline.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Spacer()

                HStack(spacing: 12) {
                    RoundIconButton(systemImage: "trash", tint: .gray) { c.clear() }
                    RoundIconButton(systemImage: "arrow.uturn.backward", tint: .orange) { c.undo() }
                    RoundIconButton(systemImage: "square.and.arrow.down", tint: .green) { c.save() }
                    PillButton(title: "Punt", systemImage: "plus.circle.fill", tint: .blue) { c.addPoint() }
                }
            }
            .padding()
        }
        .onAppear { c.start() }
        .onDisappear { c.pause() }
    }
}

struct RoundIconButton: View {
    let systemImage: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 48, height: 48)
                .background(tint, in: Circle())
                .foregroundStyle(.white)
        }
    }
}
