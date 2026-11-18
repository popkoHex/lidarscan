import Foundation
import ARKit
import ModelIO
import simd

/// Eenvoudige driehoeksmesh in wereldcoördinaten (meters, y omhoog).
struct MeshData {
    var vertices: [SIMD3<Float>] = []
    var triangles: [UInt32] = []   // 3 indices per driehoek

    var triangleCount: Int { triangles.count / 3 }
    var isEmpty: Bool { triangles.isEmpty }

    /// Bounding box over de gebruikte vertices.
    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !triangles.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in triangles {
            let v = vertices[Int(i)]
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }

    /// Voegt dubbele vertices samen (ARKit levert losse stukken met dubbele randen)
    /// en verwijdert ontaarde driehoeken. Maakt bestanden kleiner en de mesh aaneengesloten.
    func welded(tolerance: Float = 0.001) -> MeshData {
        var map = [Int64: UInt32]()
        map.reserveCapacity(vertices.count)
        var newVerts: [SIMD3<Float>] = []
        newVerts.reserveCapacity(vertices.count)
        var remap = [UInt32](repeating: 0, count: vertices.count)
        let inv = 1 / tolerance
        for (i, v) in vertices.enumerated() {
            let q = (v * inv).rounded(.toNearestOrAwayFromZero)
            let key = (Int64(q.x) & 0x1FFFFF) | ((Int64(q.y) & 0x1FFFFF) << 21) | ((Int64(q.z) & 0x1FFFFF) << 42)
            if let existing = map[key] {
                remap[i] = existing
            } else {
                let idx = UInt32(newVerts.count)
                map[key] = idx
                newVerts.append(v)
                remap[i] = idx
            }
        }
        var tris: [UInt32] = []
        tris.reserveCapacity(triangles.count)
        var t = 0
        while t + 2 < triangles.count {
            let a = remap[Int(triangles[t])], b = remap[Int(triangles[t + 1])], c = remap[Int(triangles[t + 2])]
            if a != b && b != c && a != c {
                tris.append(a); tris.append(b); tris.append(c)
            }
            t += 3
        }
        return MeshData(vertices: newVerts, triangles: tris).compacted()
    }

    /// Houdt alleen het grootste aaneengesloten stuk over (weg met losse vlekjes en stukjes vloer/muur).
    func largestComponent() -> MeshData {
        guard !triangles.isEmpty else { return self }
        var parent = Array(0..<vertices.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var t = 0
        while t + 2 < triangles.count {
            union(Int(triangles[t]), Int(triangles[t + 1]))
            union(Int(triangles[t]), Int(triangles[t + 2]))
            t += 3
        }
        var counts = [Int: Int]()
        t = 0
        while t < triangles.count {
            counts[find(Int(triangles[t])), default: 0] += 1
            t += 3
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return self }
        var tris: [UInt32] = []
        tris.reserveCapacity(counts[best]! * 3)
        t = 0
        while t + 2 < triangles.count {
            if find(Int(triangles[t])) == best {
                tris.append(triangles[t]); tris.append(triangles[t + 1]); tris.append(triangles[t + 2])
            }
            t += 3
        }
        return MeshData(vertices: vertices, triangles: tris).compacted()
    }

    /// Verwijdert ongebruikte vertices.
    func compacted() -> MeshData {
        var remap = [Int32](repeating: -1, count: vertices.count)
        var newVerts: [SIMD3<Float>] = []
        newVerts.reserveCapacity(vertices.count)
        var tris = [UInt32](repeating: 0, count: triangles.count)
        for (i, idx) in triangles.enumerated() {
            let old = Int(idx)
            if remap[old] < 0 {
                remap[old] = Int32(newVerts.count)
                newVerts.append(vertices[old])
            }
            tris[i] = UInt32(remap[old])
        }
        return MeshData(vertices: newVerts, triangles: tris)
    }
}

struct ColoredPoint {
    var position: SIMD3<Float>
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

enum MeshIOError: LocalizedError {
    case empty
    case unreadable
    var errorDescription: String? {
        switch self {
        case .empty: return "Er is (nog) niets gescand in dit gebied."
        case .unreadable: return "Bestand kon niet gelezen worden."
        }
    }
}

enum MeshIO {

    // MARK: - Inlezen

    /// Zet alle LiDAR-meshdelen van ARKit om naar één mesh in wereldcoördinaten.
    /// Optioneel alleen driehoeken binnen `radius` meter van `center`.
    static func fromARMeshAnchors(_ anchors: [ARMeshAnchor],
                                  center: SIMD3<Float>? = nil,
                                  radius: Float? = nil) -> MeshData {
        var out = MeshData()
        let totalV = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let totalF = anchors.reduce(0) { $0 + $1.geometry.faces.count }
        out.vertices.reserveCapacity(totalV)
        out.triangles.reserveCapacity(totalF * 3)
        let r2 = radius.map { $0 * $0 }

        for anchor in anchors {
            let geo = anchor.geometry
            let src = geo.vertices
            let base = UInt32(out.vertices.count)
            let T = anchor.transform

            let vptr = src.buffer.contents().advanced(by: src.offset)
            for i in 0..<src.count {
                let p = vptr.advanced(by: src.stride * i)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let w = T * SIMD4<Float>(p.0, p.1, p.2, 1)
                out.vertices.append(SIMD3<Float>(w.x, w.y, w.z))
            }

            let faces = geo.faces
            guard faces.indexCountPerPrimitive == 3 else { continue }
            let fptr = faces.buffer.contents()
            let n = faces.count
            if faces.bytesPerIndex == 4 {
                let ip = fptr.assumingMemoryBound(to: UInt32.self)
                for f in 0..<n {
                    let a = ip[f * 3], b = ip[f * 3 + 1], c = ip[f * 3 + 2]
                    if let ctr = center, let r2 {
                        if simd_distance_squared(out.vertices[Int(base + a)], ctr) > r2 { continue }
                    }
                    out.triangles.append(base + a)
                    out.triangles.append(base + b)
                    out.triangles.append(base + c)
                }
            } else {
                let ip = fptr.assumingMemoryBound(to: UInt16.self)
                for f in 0..<n {
                    let a = UInt32(ip[f * 3]), b = UInt32(ip[f * 3 + 1]), c = UInt32(ip[f * 3 + 2])
                    if let ctr = center, let r2 {
                        if simd_distance_squared(out.vertices[Int(base + a)], ctr) > r2 { continue }
                    }
                    out.triangles.append(base + a)
                    out.triangles.append(base + b)
                    out.triangles.append(base + c)
                }
            }
        }
        return out
    }

    /// Leest een USDZ/OBJ-model (bijv. uit Object Capture) in als driehoeksmesh (meters, y omhoog).
    static func fromModelFile(_ url: URL) -> MeshData? {
        let asset = MDLAsset(url: url)
        var out = MeshData()
        let meshes = (asset.childObjects(of: MDLMesh.self) as? [MDLMesh]) ?? []
        for mesh in meshes {
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            guard let attr = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition,
                                                      as: .float3) else { continue }
            let base = UInt32(out.vertices.count)
            out.vertices.reserveCapacity(out.vertices.count + mesh.vertexCount)
            for i in 0..<mesh.vertexCount {
                let p = attr.dataStart.advanced(by: i * attr.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let w = world * SIMD4<Float>(p.0, p.1, p.2, 1)
                out.vertices.append(SIMD3<Float>(w.x, w.y, w.z))
            }
            let subs = (mesh.submeshes as? [MDLSubmesh]) ?? []
            for sub in subs where sub.geometryType == .triangles {
                let buf = sub.indexBuffer(asIndexType: .uInt32)
                let map = buf.map()
                let ptr = map.bytes.assumingMemoryBound(to: UInt32.self)
                out.triangles.reserveCapacity(out.triangles.count + sub.indexCount)
                for j in 0..<sub.indexCount {
                    out.triangles.append(base + ptr[j])
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Schrijven

    /// OBJ in meters, y omhoog (standaard voor Blender, CloudCompare, enz.).
    static func writeOBJ(_ m: MeshData, to url: URL) throws {
        guard !m.isEmpty else { throw MeshIOError.empty }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        var chunk = "# LiDAR Scan export (meters, y omhoog)\n"
        chunk.reserveCapacity(1 << 20)
        func flush(force: Bool = false) {
            if force || chunk.utf8.count > 900_000 {
                fh.write(Data(chunk.utf8))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        for v in m.vertices {
            chunk += "v \(v.x) \(v.y) \(v.z)\n"
            flush()
        }
        var i = 0
        while i + 2 < m.triangles.count {
            chunk += "f \(m.triangles[i] + 1) \(m.triangles[i + 1] + 1) \(m.triangles[i + 2] + 1)\n"
            flush()
            i += 3
        }
        flush(force: true)
    }

    /// Binaire STL voor 3D-printen: millimeters, z omhoog, gecentreerd en op het printbed (z = 0).
    /// Geeft de afmetingen (b × d × h in mm) terug.
    @discardableResult
    static func writeSTL(_ m: MeshData, to url: URL) throws -> SIMD3<Float> {
        guard !m.isEmpty else { throw MeshIOError.empty }

        // y-omhoog (ARKit/USD) -> z-omhoog (slicers), meters -> mm
        var verts = m.vertices.map { v in SIMD3<Float>(v.x, -v.z, v.y) * 1000 }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for idx in m.triangles {
            let v = verts[Int(idx)]
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        let shift = SIMD3<Float>(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z)
        for i in verts.indices { verts[i] += shift }

        let triCount = m.triangleCount
        var data = Data(count: 84 + triCount * 50)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let header = Array("LiDAR Scan STL (mm, z omhoog)".utf8)
            for (i, b) in header.enumerated() { base.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
            base.storeBytes(of: UInt32(triCount).littleEndian, toByteOffset: 80, as: UInt32.self)

            var off = 84
            func put(_ v: SIMD3<Float>) {
                base.storeBytes(of: v.x, toByteOffset: off, as: Float.self)
                base.storeBytes(of: v.y, toByteOffset: off + 4, as: Float.self)
                base.storeBytes(of: v.z, toByteOffset: off + 8, as: Float.self)
                off += 12
            }
            var i = 0
            while i + 2 < m.triangles.count {
                let a = verts[Int(m.triangles[i])]
                let b = verts[Int(m.triangles[i + 1])]
                let c = verts[Int(m.triangles[i + 2])]
                let n = simd_cross(b - a, c - a)
                let len = simd_length(n)
                put(len > 0 ? n / len : .zero)
                put(a); put(b); put(c)
                base.storeBytes(of: UInt16(0), toByteOffset: off, as: UInt16.self)
                off += 2
                i += 3
            }
        }
        try data.write(to: url, options: .atomic)
        return hi - lo
    }

    /// Binaire PLY-puntenwolk met kleur, in meters (CloudCompare, MeshLab, Autodesk ReCap).
    static func writePLY(points: [ColoredPoint], to url: URL) throws {
        guard !points.isEmpty else { throw MeshIOError.empty }
        let header = "ply\nformat binary_little_endian 1.0\ncomment LiDAR Scan puntenwolk (meters, y omhoog)\n"
            + "element vertex \(points.count)\n"
            + "property float x\nproperty float y\nproperty float z\n"
            + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
        let head = Array(header.utf8)
        var data = Data(count: head.count + points.count * 15)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for (i, b) in head.enumerated() { base.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
            var off = head.count
            for p in points {
                base.storeBytes(of: p.position.x, toByteOffset: off, as: Float.self)
                base.storeBytes(of: p.position.y, toByteOffset: off + 4, as: Float.self)
                base.storeBytes(of: p.position.z, toByteOffset: off + 8, as: Float.self)
                base.storeBytes(of: p.r, toByteOffset: off + 12, as: UInt8.self)
                base.storeBytes(of: p.g, toByteOffset: off + 13, as: UInt8.self)
                base.storeBytes(of: p.b, toByteOffset: off + 14, as: UInt8.self)
                off += 15
            }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Leest een binaire little-endian PLY (punten met optioneel kleur), voor de 3D-viewer.
    static func readPLYPoints(_ url: URL, maxPoints: Int = 1_500_000) throws -> [ColoredPoint] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let endRange = data.range(of: Data("end_header\n".utf8)) else { throw MeshIOError.unreadable }
        guard let header = String(data: data[data.startIndex..<endRange.lowerBound], encoding: .ascii),
              header.contains("binary_little_endian") else { throw MeshIOError.unreadable }

        var count = 0
        var stride = 0
        var offsets: [String: (Int, String)] = [:]
        var inVertex = false
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            if parts.first == "element" {
                inVertex = parts.count >= 3 && parts[1] == "vertex"
                if inVertex { count = Int(parts[2]) ?? 0 }
            } else if parts.first == "property", inVertex, parts.count >= 3, parts[1] != "list" {
                let type = parts[1]
                let size: Int
                switch type {
                case "char", "uchar", "int8", "uint8": size = 1
                case "short", "ushort", "int16", "uint16": size = 2
                case "int", "uint", "float", "int32", "uint32", "float32": size = 4
                case "double", "float64": size = 8
                default: size = 4
                }
                offsets[parts[2]] = (stride, type)
                stride += size
            }
        }
        guard count > 0, stride > 0,
              let ox = offsets["x"], let oy = offsets["y"], let oz = offsets["z"],
              ox.1.hasPrefix("float"), oy.1.hasPrefix("float"), oz.1.hasPrefix("float") else {
            throw MeshIOError.unreadable
        }
        let colorOK = offsets["red"]?.1.contains("char") == true || offsets["red"]?.1 == "uint8"
        let start = endRange.upperBound - data.startIndex
        guard data.count >= start + count * stride else { throw MeshIOError.unreadable }
        let step = max(1, count / maxPoints)

        var out: [ColoredPoint] = []
        out.reserveCapacity(count / step + 1)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var i = 0
            while i < count {
                let p = base.advanced(by: start + i * stride)
                let x = p.loadUnaligned(fromByteOffset: ox.0, as: Float.self)
                let y = p.loadUnaligned(fromByteOffset: oy.0, as: Float.self)
                let z = p.loadUnaligned(fromByteOffset: oz.0, as: Float.self)
                var r: UInt8 = 200, g: UInt8 = 200, b: UInt8 = 200
                if colorOK, let orr = offsets["red"], let og = offsets["green"], let ob = offsets["blue"] {
                    r = p.load(fromByteOffset: orr.0, as: UInt8.self)
                    g = p.load(fromByteOffset: og.0, as: UInt8.self)
                    b = p.load(fromByteOffset: ob.0, as: UInt8.self)
                }
                out.append(ColoredPoint(position: SIMD3<Float>(x, y, z), r: r, g: g, b: b))
                i += step
            }
        }
        return out
    }
}

/// Bouwt een gekleurde puntenwolk uit de LiDAR-dieptekaart + camerabeeld.
enum PointCloudBuilder {
    static let voxelSize: Float = 0.005   // 5 mm: dubbele punten worden overgeslagen

    static func append(from frame: ARFrame,
                       into points: inout [ColoredPoint],
                       occupied: inout Set<Int64>,
                       step: Int = 2,
                       maxDepth: Float = 4) {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depth = sceneDepth.depthMap
        let conf = sceneDepth.confidenceMap
        let image = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(image) >= 2 else { return }

        CVPixelBufferLockBaseAddress(depth, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let conf { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let conf { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
        }

        guard let dBase = CVPixelBufferGetBaseAddress(depth),
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }

        let dw = CVPixelBufferGetWidth(depth)
        let dh = CVPixelBufferGetHeight(depth)
        let dRow = CVPixelBufferGetBytesPerRow(depth)
        let cBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }
        let cRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let iw = CVPixelBufferGetWidthOfPlane(image, 0)
        let ih = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)

        // Camera-intrinsics gelden voor het camerabeeld; schalen naar de dieptekaart.
        let K = frame.camera.intrinsics
        let sx = Float(dw) / Float(iw)
        let sy = Float(dh) / Float(ih)
        let fx = K[0][0] * sx, fy = K[1][1] * sy
        let cx = K[2][0] * sx, cy = K[2][1] * sy
        let T = frame.camera.transform

        for y in Swift.stride(from: 0, to: dh, by: step) {
            for x in Swift.stride(from: 0, to: dw, by: step) {
                if let cBase {
                    let c = cBase.advanced(by: y * cRow + x).load(as: UInt8.self)
                    if c < 2 { continue }   // alleen hoge betrouwbaarheid
                }
                let d = dBase.advanced(by: y * dRow + x * 4).load(as: Float32.self)
                if d < 0.1 || d > maxDepth { continue }

                let xc = (Float(x) + 0.5 - cx) * d / fx
                let yc = -(Float(y) + 0.5 - cy) * d / fy
                let w4 = T * SIMD4<Float>(xc, yc, -d, 1)
                let w = SIMD3<Float>(w4.x, w4.y, w4.z)

                let key = voxelKey(w)
                if !occupied.insert(key).inserted { continue }

                let ix = min(iw - 1, Int((Float(x) + 0.5) / sx))
                let iy = min(ih - 1, Int((Float(y) + 0.5) / sy))
                let Y = Float(yBase.advanced(by: iy * yRow + ix).load(as: UInt8.self))
                let uvOff = (iy / 2) * uvRow + (ix / 2) * 2
                let cb = Float(uvBase.advanced(by: uvOff).load(as: UInt8.self)) - 128
                let cr = Float(uvBase.advanced(by: uvOff + 1).load(as: UInt8.self)) - 128
                let r = Y + 1.402 * cr
                let g = Y - 0.344136 * cb - 0.714136 * cr
                let b = Y + 1.772 * cb

                points.append(ColoredPoint(position: w, r: clamp8(r), g: clamp8(g), b: clamp8(b)))
            }
        }
    }

    private static func clamp8(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v)))
    }

    private static func voxelKey(_ p: SIMD3<Float>) -> Int64 {
        let ix = Int64((p.x / voxelSize).rounded(.down)) & 0x1FFFFF
        let iy = Int64((p.y / voxelSize).rounded(.down)) & 0x1FFFFF
        let iz = Int64((p.z / voxelSize).rounded(.down)) & 0x1FFFFF
        return ix | (iy << 21) | (iz << 42)
    }
}
