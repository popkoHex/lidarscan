import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO

/// Eenvoudige 3D-viewer voor STL, OBJ en PLY (mesh of puntenwolk), met afmetingen.
struct ModelViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scene: SCNScene?
    @State private var info = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let scene {
                    SceneView(scene: scene,
                              options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    Text("Kon dit model niet openen.").foregroundStyle(.white)
                } else {
                    ProgressView("Model laden…").tint(.white).foregroundStyle(.white)
                }
                VStack {
                    Spacer()
                    if !info.isEmpty {
                        Text(info)
                            .font(.footnote.monospacedDigit())
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sluit") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let url = self.url
        let result: (SCNScene, String)? = await Task.detached(priority: .userInitiated) {
            ModelViewer.buildScene(url: url)
        }.value
        if let result {
            scene = result.0
            info = result.1
        } else {
            failed = true
        }
    }

    nonisolated static func buildScene(url: URL) -> (SCNScene, String)? {
        let ext = url.pathExtension.lowercased()
        let content = SCNNode()
        var unitsToMM: Float = 1000      // OBJ/PLY/USDZ in meters
        var zUp = false

        if ext == "ply" {
            guard let pts = try? MeshIO.readPLYPoints(url), !pts.isEmpty else { return nil }
            content.addChildNode(pointNode(pts))
        } else {
            let asset = MDLAsset(url: url)
            asset.loadTextures()
            let s = SCNScene(mdlAsset: asset)
            for child in s.rootNode.childNodes {
                content.addChildNode(child)
            }
            if ext == "stl" {
                unitsToMM = 1      // onze STL is in mm, z omhoog
                zUp = true
            }
            content.enumerateHierarchy { node, _ in
                node.geometry?.materials.forEach { $0.isDoubleSided = true }
                if let g = node.geometry, g.firstMaterial?.diffuse.contents == nil || ext == "stl" {
                    g.firstMaterial?.diffuse.contents = UIColor(white: 0.82, alpha: 1)
                }
            }
        }

        // Afmetingen en centreren/schalen naar ±1 eenheid
        let flat = content.flattenedClone()
        let (lo, hi) = flat.boundingBox
        let size = SIMD3<Float>(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let maxDim = max(size.x, size.y, size.z)
        guard maxDim > 0 else { return nil }

        let holder = SCNNode()
        holder.addChildNode(content)
        content.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        holder.scale = SCNVector3(repeating: 2 / maxDim)
        if zUp { holder.eulerAngles.x = -.pi / 2 }

        let scene = SCNScene()
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(holder)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.01
        cam.position = SCNVector3(0, 0.8, 3.2)
        cam.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cam)

        // b × d × h in mm (h = verticale as)
        let mm = size * unitsToMM
        let (b, d, h) = zUp ? (mm.x, mm.y, mm.z) : (mm.x, mm.z, mm.y)
        let text = String(format: "Afmeting: %.0f × %.0f × %.0f mm (b × d × h)", b, d, h)
        return (scene, text)
    }

    nonisolated static func pointNode(_ pts: [ColoredPoint]) -> SCNNode {
        let n = pts.count
        let verts = pts.map { SCNVector3($0.position.x, $0.position.y, $0.position.z) }
        var colors = [Float]()
        colors.reserveCapacity(n * 3)
        for p in pts {
            colors.append(Float(p.r) / 255)
            colors.append(Float(p.g) / 255)
            colors.append(Float(p.b) / 255)
        }
        let vSrc = SCNGeometrySource(vertices: verts)
        let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let cSrc = SCNGeometrySource(data: cData, semantic: .color, vectorCount: n,
                                     usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let idx = (0..<UInt32(n)).map { $0 }
        let iData = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        let el = SCNGeometryElement(data: iData, primitiveType: .point, primitiveCount: n, bytesPerIndex: 4)
        el.pointSize = 3
        el.minimumPointScreenSpaceRadius = 1
        el.maximumPointScreenSpaceRadius = 4
        let geo = SCNGeometry(sources: [vSrc, cSrc], elements: [el])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }
}

private extension SCNVector3 {
    init(repeating v: Float) { self.init(v, v, v) }
}
