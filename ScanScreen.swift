import SwiftUI
import RealityKit
import ARKit

/// LiDAR-mesh scannen (OBJ/STL) en gekleurde puntenwolk opnemen (PLY).
final class ScanController: NSObject, ObservableObject, ARSessionDelegate {
    let arView = ARView(frame: .zero)

    @Published var isRecordingPoints = false
    @Published var pointCount = 0
    @Published var triangleCount = 0
    @Published var message = ""
    @Published var isBusy = false

    private var points: [ColoredPoint] = []
    private var occupied = Set<Int64>()
    private var lastPointTime: TimeInterval = 0
    private var lastStatsTime: TimeInterval = 0
    private let maxPoints = 4_000_000

    override init() {
        super.init()
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
    }

    var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func start(reset: Bool = false) {
        guard hasLiDAR else {
            message = "Dit toestel heeft geen LiDAR-scanner."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.debugOptions.insert(.showSceneUnderstanding)
        if reset {
            points.removeAll()
            occupied.removeAll()
            pointCount = 0
            triangleCount = 0
            isRecordingPoints = false
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        } else {
            arView.session.run(config)
        }
    }

    func pause() {
        isRecordingPoints = false
        arView.session.pause()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didFailWithError error: Error) {
        message = "AR-fout: \(error.localizedDescription)"
    }

    func sessionWasInterrupted(_ session: ARSession) {
        isRecordingPoints = false
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.timestamp
        if isRecordingPoints, t - lastPointTime > 0.3, points.count < maxPoints {
            lastPointTime = t
            PointCloudBuilder.append(from: frame, into: &points, occupied: &occupied)
            pointCount = points.count
            if points.count >= maxPoints {
                isRecordingPoints = false
                message = "Maximum aantal punten bereikt."
            }
        }
        if t - lastStatsTime > 1 {
            lastStatsTime = t
            triangleCount = frame.anchors
                .compactMap { $0 as? ARMeshAnchor }
                .reduce(0) { $0 + $1.geometry.faces.count }
        }
    }

    // MARK: Export

    private func meshAnchors() -> [ARMeshAnchor] {
        arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    }

    /// Punt in het midden van het scherm (voor 'alleen object in het midden').
    private func centerPoint() -> SIMD3<Float>? {
        let c = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let r = arView.raycast(from: c, allowing: .estimatedPlane, alignment: .any).first else {
            return nil
        }
        let p = r.worldTransform.columns.3
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    enum MeshFormat { case obj, stl }

    func exportMesh(_ format: MeshFormat, cropRadius: Float?, onlyLargest: Bool) {
        let anchors = meshAnchors()
        guard !anchors.isEmpty else {
            message = "Nog geen mesh. Beweeg de telefoon langzaam rond."
            return
        }
        var center: SIMD3<Float>? = nil
        if cropRadius != nil {
            center = centerPoint()
            if center == nil {
                message = "Richt het kruisje op het object en probeer opnieuw."
                return
            }
        }
        isBusy = true
        message = ""
        let name = "Scan \(Storage.stamp())"
        DispatchQueue.global(qos: .userInitiated).async {
            var mesh = MeshIO.fromARMeshAnchors(anchors, center: center, radius: cropRadius).welded()
            if onlyLargest { mesh = mesh.largestComponent() }
            var result: String
            var ok = true
            do {
                switch format {
                case .obj:
                    try MeshIO.writeOBJ(mesh, to: Storage.url(name + ".obj"))
                    var dims = ""
                    if let bb = mesh.bounds() {
                        let s = (bb.max - bb.min) * 100
                        dims = String(format: " · %.0f × %.0f × %.0f cm", s.x, s.z, s.y)
                    }
                    result = "Opgeslagen: \(name).obj (\(mesh.triangleCount) driehoeken\(dims))"
                case .stl:
                    let s = try MeshIO.writeSTL(mesh, to: Storage.url(name + ".stl"))
                    result = String(format: "Opgeslagen: %@.stl · %.0f × %.0f × %.0f mm (b×d×h)",
                                    name, s.x, s.y, s.z)
                }
            } catch {
                ok = false
                result = "Fout: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.message = result
                Haptics.notify(ok ? .success : .error)
            }
        }
    }

    func exportPointCloud() {
        guard !points.isEmpty else {
            message = "Nog geen punten. Tik eerst op ‘Neem punten op’."
            return
        }
        let snapshot = points
        isBusy = true
        let name = "Puntenwolk \(Storage.stamp()).ply"
        DispatchQueue.global(qos: .userInitiated).async {
            var result: String
            do {
                try MeshIO.writePLY(points: snapshot, to: Storage.url(name))
                result = "Opgeslagen: \(name) (\(snapshot.count) punten)"
            } catch {
                result = "Fout: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.message = result
                Haptics.notify(.success)
            }
        }
    }
}

struct ScanScreen: View {
    @StateObject private var c = ScanController()
    @State private var cropToCenter = false
    @State private var cropRadius: Float = 0.5
    @State private var onlyLargest = true

    var body: some View {
        ZStack {
            ARViewContainer(arView: c.arView).ignoresSafeArea()

            if cropToCenter {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.yellow)
            }

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mesh: \(c.triangleCount) driehoeken")
                        Text("Puntenwolk: \(c.pointCount) punten")
                    }
                    .font(.caption.monospacedDigit())
                    Spacer()
                    Button {
                        c.start(reset: true)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title3)
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                if !c.message.isEmpty {
                    Text(c.message)
                        .font(.footnote)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer()

                VStack(spacing: 8) {
                    Toggle("Alleen object rond het kruisje", isOn: $cropToCenter)
                    if cropToCenter {
                        Toggle("Alleen grootste stuk (losse rommel weg)", isOn: $onlyLargest)
                        HStack {
                            Text("Straal")
                            Slider(value: $cropRadius, in: 0.1...2.0, step: 0.05)
                            Text(String(format: "%.2f m", cropRadius))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.subheadline)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 10) {
                    PillButton(title: c.isRecordingPoints ? "Stop punten" : "Neem punten op",
                               systemImage: c.isRecordingPoints ? "stop.circle" : "record.circle",
                               tint: c.isRecordingPoints ? .red : .blue) {
                        c.isRecordingPoints.toggle()
                        Haptics.tap()
                    }

                    Menu {
                        Button("Mesh als STL (3D-print, mm)") {
                            c.exportMesh(.stl, cropRadius: cropToCenter ? cropRadius : nil, onlyLargest: cropToCenter && onlyLargest)
                        }
                        Button("Mesh als OBJ (meters)") {
                            c.exportMesh(.obj, cropRadius: cropToCenter ? cropRadius : nil, onlyLargest: cropToCenter && onlyLargest)
                        }
                        Button("Puntenwolk als PLY (kleur)") {
                            c.exportPointCloud()
                        }
                    } label: {
                        Label("Opslaan", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.green, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .disabled(c.isBusy)
                }
                if c.isBusy { ProgressView("Bezig met opslaan…") }
            }
            .padding()
        }
        .onAppear { c.start() }
        .onDisappear { c.pause() }
    }
}
