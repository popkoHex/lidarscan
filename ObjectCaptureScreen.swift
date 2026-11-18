import SwiftUI
import RealityKit
import QuickLook

/// Apple Object Capture: hoge kwaliteit 3D-model van een object, verwerkt op de iPhone zelf.
/// Resultaat: USDZ (met textuur) + STL in mm voor de 3D-printer.
@MainActor
final class CaptureModel: ObservableObject {
    enum Step { case idle, initializing, ready, detecting, capturing, finishing, processing, done, failed }

    @Published var session: ObjectCaptureSession?
    @Published var step: Step = .idle
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var resultUSDZ: URL?
    @Published var passCompleted = false
    @Published var passCount = 1

    private var workDir: URL?
    private var stateTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?

    var isSupported: Bool { ObjectCaptureSession.isSupported }

    func start() {
        guard isSupported else {
            message = "Object Capture wordt niet ondersteund op dit toestel."
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObjectCapture-\(UUID().uuidString)", isDirectory: true)
        let images = dir.appendingPathComponent("Images/", isDirectory: true)
        let checkpoints = dir.appendingPathComponent("Checkpoints/", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        } catch {
            message = "Kon werkmap niet maken: \(error.localizedDescription)"
            return
        }
        workDir = dir
        resultUSDZ = nil
        progress = 0
        message = ""

        let s = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = checkpoints
        do {
            try s.start(imagesDirectory: images, configuration: config)
        } catch {
            message = "Starten mislukt: \(error.localizedDescription)"
            return
        }
        session = s
        step = .initializing

        passCompleted = false
        passCount = 1
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in s.stateUpdates {
                self?.handle(state)
            }
        }
        // Houdt bij of een volledige rondgang klaar is
        passTask?.cancel()
        passTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, let session = self.session else { break }
                let done = session.userCompletedScanPass
                if done != self.passCompleted {
                    self.passCompleted = done
                    if done { Haptics.notify(.success) }
                }
            }
        }
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .initializing: step = .initializing
        case .ready: step = .ready
        case .detecting: step = .detecting
        case .capturing: step = .capturing
        case .finishing: step = .finishing
        case .completed:
            passTask?.cancel()
            session = nil
            step = .processing
            Task { await reconstruct() }
        case .failed(let error):
            passTask?.cancel()
            session = nil
            step = .failed
            message = "Opname mislukt: \(error.localizedDescription)"
        @unknown default:
            break
        }
    }

    func detect() { _ = session?.startDetecting(); Haptics.tap() }
    func capture() { session?.startCapturing(); Haptics.tap() }
    func finish() { session?.finish() }

    /// Nog een rondgang, object in dezelfde stand (bijv. hoger of lager rondlopen).
    func nextPass() {
        session?.beginNewScanPass()
        passCompleted = false
        passCount += 1
    }

    /// Nog een rondgang nadat je het object hebt omgedraaid (onderkant meenemen).
    func nextPassFlipped() {
        session?.beginNewScanPassAfterFlip()
        passCompleted = false
        passCount += 1
    }

    func cancel() {
        session?.cancel()
        session = nil
        stateTask?.cancel()
        passTask?.cancel()
        step = .idle
        cleanup()
    }

    private func reconstruct() async {
        guard let dir = workDir else { return }
        let images = dir.appendingPathComponent("Images/", isDirectory: true)
        let base = "Object \(Storage.stamp())"
        let usdz = Storage.url(base + ".usdz")
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = dir.appendingPathComponent("Checkpoints/", isDirectory: true)
            let ps = try PhotogrammetrySession(input: images, configuration: config)
            try ps.process(requests: [.modelFile(url: usdz)])
            for try await output in ps.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress = fraction
                case .requestError(_, let error):
                    throw error
                case .processingComplete:
                    break
                default:
                    break
                }
            }
            // STL voor de printer (op de achtergrond)
            let stlURL = Storage.url(base + ".stl")
            let size: SIMD3<Float>? = await Task.detached(priority: .userInitiated) {
                guard let mesh = MeshIO.fromModelFile(usdz)?.welded(tolerance: 0.0002) else { return nil }
                return try? MeshIO.writeSTL(mesh, to: stlURL)
            }.value
            if let size {
                message = String(format: "Klaar! ‘%@’ (.usdz + .stl) staat bij Bestanden.\nAfmeting: %.0f × %.0f × %.0f mm – controleer dit met een duimstok.",
                                 base, size.x, size.y, size.z)
            } else {
                message = "USDZ opgeslagen, maar STL maken lukte niet."
            }
            resultUSDZ = usdz
            step = .done
            Haptics.notify(.success)
        } catch {
            message = "Verwerken mislukt: \(error.localizedDescription)"
            step = .failed
        }
        cleanup()
    }

    private func cleanup() {
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
    }
}

struct ObjectCaptureScreen: View {
    @StateObject private var m = CaptureModel()
    @State private var preview: URL?

    var body: some View {
        ZStack {
            if let session = m.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            } else {
                idleContent
            }

            if m.session != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button("Annuleer") { m.cancel() }
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    captureButtons
                }
                .padding()
            }
        }
        .quickLookPreview($preview)
    }

    @ViewBuilder private var captureButtons: some View {
        switch m.step {
        case .ready:
            VStack(spacing: 6) {
                Text("Richt op het object in het midden").font(.footnote)
                PillButton(title: "Object vastzetten", systemImage: "viewfinder", tint: .blue) { m.detect() }
            }
        case .detecting:
            VStack(spacing: 6) {
                Text("Pas het kader aan zodat het object erin past").font(.footnote)
                PillButton(title: "Start opname", systemImage: "record.circle", tint: .red) { m.capture() }
            }
        case .capturing:
            if m.passCompleted {
                VStack(spacing: 8) {
                    Text("Rondgang \(m.passCount) klaar! Voor het beste resultaat: 3 rondes (laag, midden, hoog) of draai het object om.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    HStack(spacing: 8) {
                        PillButton(title: "Nog een ronde", systemImage: "arrow.clockwise", tint: .blue) { m.nextPass() }
                        PillButton(title: "Omgedraaid", systemImage: "arrow.up.arrow.down", tint: .orange) { m.nextPassFlipped() }
                    }
                    PillButton(title: "Klaar – maak 3D-model", systemImage: "checkmark.circle", tint: .green) { m.finish() }
                }
            } else {
                VStack(spacing: 6) {
                    Text("Ronde \(m.passCount): loop langzaam rondom het object")
                        .font(.footnote)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                    PillButton(title: "Nu al klaar", systemImage: "checkmark.circle", tint: .green) { m.finish() }
                }
            }
        case .finishing, .initializing:
            ProgressView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var idleContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "printer")
                .font(.system(size: 60))
            Text("Scan voor 3D-printen").font(.title2.bold())

            switch m.step {
            case .processing:
                ProgressView(value: m.progress)
                    .padding(.horizontal, 40)
                Text("Model wordt op je iPhone berekend… \(Int(m.progress * 100))%")
                    .font(.footnote)
                Text("Houd de app open. Dit kan enkele minuten duren.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                Text("Gebruikt Apple Object Capture (foto’s + LiDAR) voor een gedetailleerd model. Werkt het best met objecten van ca. 10 cm tot 1 m, met structuur en mat oppervlak. Je krijgt een USDZ (met kleur) en een STL in millimeters.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if !m.message.isEmpty {
                    Text(m.message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let url = m.resultUSDZ {
                    Button("Bekijk 3D-model") { preview = url }
                }

                PillButton(title: "Nieuwe objectscan", systemImage: "camera.viewfinder", tint: .blue) {
                    m.start()
                }
            }
        }
        .padding()
    }
}
