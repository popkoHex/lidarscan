import SwiftUI
import RoomPlan
import UIKit
import simd

/// Ruimte scannen met Apple RoomPlan: 3D-model (USDZ), plattegrond (PNG) en maten (TXT).
final class RoomController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    // RoomCaptureViewDelegate vereist NSSecureCoding
    static var supportsSecureCoding: Bool { true }
    func encode(with coder: NSCoder) {}
    required init?(coder: NSCoder) { super.init() }
    override init() { super.init() }

    lazy var captureView: RoomCaptureView = {
        let v = RoomCaptureView(frame: .zero)
        v.delegate = self
        return v
    }()

    @Published var isScanning = false
    @Published var isProcessing = false
    @Published var room: CapturedRoom?
    @Published var planImage: UIImage?
    @Published var report = ""
    @Published var message = ""

    var isSupported: Bool { RoomCaptureSession.isSupported }

    func start() {
        guard isSupported else {
            message = "RoomPlan wordt niet ondersteund op dit toestel."
            return
        }
        room = nil
        planImage = nil
        report = ""
        message = ""
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
    }

    func stop() {
        guard isScanning else { return }
        captureView.captureSession.stop()
        isScanning = false
        isProcessing = true
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            self.isProcessing = false
            if let error {
                self.message = "Fout: \(error.localizedDescription)"
            }
            self.room = processedResult
            self.report = RoomReport.text(for: processedResult)
            self.planImage = RoomReport.planImage(for: processedResult)
        }
    }

    // MARK: Opslaan

    func save() {
        guard let room else { return }
        let base = "Kamer \(Storage.stamp())"
        do {
            try room.export(to: Storage.url(base + ".usdz"), exportOptions: .parametric)
            try report.write(to: Storage.url(base + " maten.txt"), atomically: true, encoding: .utf8)
            if let png = planImage?.pngData() {
                try png.write(to: Storage.url(base + " plattegrond.png"))
            }
            let pdf = RoomReport.pdf(plan: planImage, report: report)
            try pdf.write(to: Storage.url(base + ".pdf"))
            message = "Opgeslagen als ‘\(base)’: PDF, 3D-model (USDZ), plattegrond (PNG) en maten (TXT)."
            Haptics.notify(.success)
        } catch {
            message = "Opslaan mislukt: \(error.localizedDescription)"
        }
    }
}

enum RoomReport {

    /// A4-PDF met plattegrond en maten, handig voor offertes en de klant.
    static func pdf(plan: UIImage?, report: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 40
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y = margin
            if let plan {
                let maxW = page.width - 2 * margin
                let maxH: CGFloat = 470
                let ratio = min(maxW / plan.size.width, maxH / plan.size.height)
                let size = CGSize(width: plan.size.width * ratio, height: plan.size.height * ratio)
                plan.draw(in: CGRect(x: (page.width - size.width) / 2, y: y, width: size.width, height: size.height))
                y += size.height + 20
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: UIColor.black
            ]
            let lineH: CGFloat = 14
            for line in report.components(separatedBy: "\n") {
                if y + lineH > page.height - margin {
                    ctx.beginPage()
                    y = margin
                }
                NSString(string: line).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
                y += lineH
            }
        }
    }

    static func cm(_ m: Float) -> String { String(format: "%.0f cm", m * 100) }

    static func floorArea(_ room: CapturedRoom) -> Float? {
        guard let floor = room.floors.first else { return nil }
        let pts = floor.polygonCorners
        guard pts.count >= 3 else {
            let d = floor.dimensions
            return d.x * max(d.y, d.z)
        }
        // Schoenveter-formule; vlak kan in x/y of x/z liggen, neem de grootste.
        func shoelace(_ a: (SIMD3<Float>) -> Float, _ b: (SIMD3<Float>) -> Float) -> Float {
            var s: Float = 0
            for i in 0..<pts.count {
                let p = pts[i], q = pts[(i + 1) % pts.count]
                s += a(p) * b(q) - a(q) * b(p)
            }
            return abs(s) / 2
        }
        return max(shoelace({ $0.x }, { $0.y }), shoelace({ $0.x }, { $0.z }))
    }

    static func text(for room: CapturedRoom) -> String {
        var lines: [String] = ["KAMERSCAN – \(Storage.stamp())", ""]

        if let a = floorArea(room) {
            lines.append(String(format: "Vloeroppervlak: %.2f m²", a))
        }
        let wallArea = room.walls.reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
        let openingArea = (room.doors + room.windows + room.openings)
            .reduce(Float(0)) { $0 + $1.dimensions.x * $1.dimensions.y }
        lines.append(String(format: "Wandoppervlak bruto: %.2f m²", wallArea))
        lines.append(String(format: "Wandoppervlak netto (zonder deuren/ramen): %.2f m²",
                            max(0, wallArea - openingArea)))
        if let h = room.walls.map({ $0.dimensions.y }).max() {
            lines.append("Plafondhoogte (max wand): \(cm(h))")
        }
        lines.append("")

        lines.append("MUREN (\(room.walls.count))")
        for (i, w) in room.walls.enumerated() {
            lines.append("  Muur \(i + 1): \(cm(w.dimensions.x)) breed × \(cm(w.dimensions.y)) hoog")
        }
        lines.append("DEUREN (\(room.doors.count))")
        for (i, d) in room.doors.enumerated() {
            lines.append("  Deur \(i + 1): \(cm(d.dimensions.x)) × \(cm(d.dimensions.y))")
        }
        lines.append("RAMEN (\(room.windows.count))")
        for (i, w) in room.windows.enumerated() {
            lines.append("  Raam \(i + 1): \(cm(w.dimensions.x)) × \(cm(w.dimensions.y))")
        }
        lines.append("OPENINGEN (\(room.openings.count))")
        for (i, o) in room.openings.enumerated() {
            lines.append("  Opening \(i + 1): \(cm(o.dimensions.x)) × \(cm(o.dimensions.y))")
        }
        lines.append("OBJECTEN (\(room.objects.count))")
        for o in room.objects {
            let d = o.dimensions
            lines.append("  \(String(describing: o.category)): \(cm(d.x)) × \(cm(d.z)) × \(cm(d.y)) (b×d×h)")
        }
        return lines.joined(separator: "\n")
    }

    /// Bovenaanzicht van de muren, deuren en ramen met maten.
    static func planImage(for room: CapturedRoom) -> UIImage? {
        typealias Seg = (a: CGPoint, b: CGPoint, len: Float)

        func segment(_ s: CapturedRoom.Surface) -> Seg {
            let t = s.transform
            let c = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let dir = simd_normalize(SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z))
            let half = s.dimensions.x / 2
            let p1 = c - dir * half, p2 = c + dir * half
            return (CGPoint(x: CGFloat(p1.x), y: CGFloat(p1.z)),
                    CGPoint(x: CGFloat(p2.x), y: CGFloat(p2.z)),
                    s.dimensions.x)
        }

        let walls = room.walls.map(segment)
        guard !walls.isEmpty else { return nil }
        let doors = room.doors.map(segment)
        let windows = room.windows.map(segment)
        let openings = room.openings.map(segment)

        let all = walls.flatMap { [$0.a, $0.b] }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let w = max(maxX - minX, 0.5), h = max(maxY - minY, 0.5)

        let canvas: CGFloat = 1600
        let margin: CGFloat = 140
        let scale = (canvas - 2 * margin) / max(w, h)
        let size = CGSize(width: w * scale + 2 * margin, height: h * scale + 2 * margin + 80)

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - minX) * scale + margin, y: (p.y - minY) * scale + margin + 80)
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill()
            g.fill(CGRect(origin: .zero, size: size))
            g.setLineCap(.round)

            func draw(_ segs: [Seg], color: UIColor, width: CGFloat) {
                g.setStrokeColor(color.cgColor)
                g.setLineWidth(width)
                for s in segs {
                    g.move(to: map(s.a))
                    g.addLine(to: map(s.b))
                    g.strokePath()
                }
            }

            draw(walls, color: .black, width: 10)
            draw(openings, color: .white, width: 12)
            draw(doors, color: .systemOrange, width: 12)
            draw(windows, color: .systemBlue, width: 12)

            // Maatlabels bij de muren
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor.darkGray,
                .backgroundColor: UIColor.white.withAlphaComponent(0.85)
            ]
            for s in walls {
                let m = CGPoint(x: (s.a.x + s.b.x) / 2, y: (s.a.y + s.b.y) / 2)
                let p = map(m)
                let str = NSString(string: cm(s.len))
                let sz = str.size(withAttributes: attrs)
                str.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: attrs)
            }

            // Titel + legenda + schaalbalk 1 m
            let title: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            var head = "Plattegrond"
            if let a = floorArea(room) { head += String(format: " – %.2f m²", a) }
            NSString(string: head).draw(at: CGPoint(x: 40, y: 24), withAttributes: title)

            let small: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.darkGray
            ]
            NSString(string: "Oranje = deur, blauw = raam").draw(at: CGPoint(x: 40, y: size.height - 50),
                                                                   withAttributes: small)
            let barY = size.height - 70
            let barX = size.width - 40 - scale
            g.setStrokeColor(UIColor.black.cgColor)
            g.setLineWidth(4)
            g.move(to: CGPoint(x: barX, y: barY))
            g.addLine(to: CGPoint(x: barX + scale, y: barY))
            g.strokePath()
            NSString(string: "1 m").draw(at: CGPoint(x: barX + scale / 2 - 20, y: barY + 6), withAttributes: small)
        }
    }
}

struct RoomCaptureContainer: UIViewRepresentable {
    let controller: RoomController
    func makeUIView(context: Context) -> RoomCaptureView { controller.captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct RoomScreen: View {
    @StateObject private var c = RoomController()

    var body: some View {
        Group {
            if c.isScanning || c.isProcessing || c.room == nil {
                ZStack {
                    if c.isScanning || c.isProcessing {
                        RoomCaptureContainer(controller: c).ignoresSafeArea()
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "square.split.bottomrightquarter")
                                .font(.system(size: 60))
                            Text("Kamer scannen").font(.title2.bold())
                            Text("Loop langzaam door de ruimte en richt op muren, deuren en ramen. Je krijgt een 3D-model, plattegrond met maten en een lijst met oppervlaktes.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                    VStack {
                        Spacer()
                        if !c.message.isEmpty { Text(c.message).font(.footnote).padding(8) }
                        if c.isProcessing {
                            ProgressView("Plattegrond maken…")
                        } else if c.isScanning {
                            PillButton(title: "Klaar", systemImage: "checkmark.circle", tint: .green) { c.stop() }
                        } else {
                            PillButton(title: "Start kamerscan", systemImage: "play.circle", tint: .blue) { c.start() }
                        }
                    }
                    .padding()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let img = c.planImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Text(c.report)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        if !c.message.isEmpty { Text(c.message).foregroundStyle(.green) }
                        HStack {
                            PillButton(title: "Opslaan", systemImage: "square.and.arrow.down", tint: .green) { c.save() }
                            PillButton(title: "Nieuwe scan", systemImage: "arrow.counterclockwise", tint: .blue) { c.start() }
                        }
                    }
                    .padding()
                }
            }
        }
        .onDisappear { if c.isScanning { c.captureView.captureSession.stop(); c.isScanning = false } }
    }
}
