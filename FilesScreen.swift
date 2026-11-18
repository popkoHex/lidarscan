import SwiftUI
import QuickLook

/// Overzicht van alle opgeslagen scans, met bekijken, delen en verwijderen.
/// De bestanden staan ook in de Bestanden-app onder ‘Op mijn iPhone › LiDAR Scan’.
struct FilesScreen: View {
    struct Item: Identifiable {
        let url: URL
        let size: Int64
        let date: Date
        var id: URL { url }
    }

    struct ViewerTarget: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @State private var items: [Item] = []
    @State private var preview: URL?
    @State private var viewer: ViewerTarget?

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("Nog geen scans opgeslagen.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tik om te bekijken (3D-viewer met afmetingen), veeg naar links om te verwijderen. Bestanden staan ook in de Bestanden-app onder Op mijn iPhone › LiDAR Scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack {
                        Image(systemName: icon(for: item.url))
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(item.url.lastPathComponent).lineLimit(2)
                            Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: item.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(item.url) }
                }
                .onDelete { idx in
                    for i in idx { try? FileManager.default.removeItem(at: items[i].url) }
                    load()
                }
            }
            .navigationTitle("Bestanden")
            .refreshable { load() }
            .onAppear { load() }
            .quickLookPreview($preview)
            .fullScreenCover(item: $viewer) { target in
                ModelViewer(url: target.url)
            }
        }
    }

    private func open(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "stl", "obj", "ply":
            viewer = ViewerTarget(url: url)
        case "usdz", "png", "txt", "pdf":
            preview = url
        default:
            break
        }
    }

    private func load() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Storage.documents,
                                                                 includingPropertiesForKeys: keys)) ?? []
        items = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { return nil }
            return Item(url: url, size: Int64(v.fileSize ?? 0), date: v.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "stl": return "printer"
        case "obj", "usdz": return "cube"
        case "ply": return "circle.grid.3x3"
        case "png": return "map"
        case "pdf": return "doc.richtext"
        case "txt": return "ruler"
        default: return "doc"
        }
    }
}
