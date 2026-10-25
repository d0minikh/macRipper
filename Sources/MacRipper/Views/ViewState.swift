import SwiftUI
import ImageIO

/// SwiftUI's `@State` resolves to a compiler macro in newer SDKs, whose plugin only ships with
/// full Xcode. This alias uses the underlying property wrapper so the app also builds with the
/// Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

extension AppAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

/// Decoded images, scaled down to the size they are shown at. A 3000 px cover decodes to about 36 MB;
/// a 64 px sidebar thumbnail of it needs 16 KB.
enum CoverCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 64 * 1024 * 1024    // decoded bytes
        return c
    }()

    /// The key includes size and byte count: a replaced cover reuses the same file name.
    static func image(for cover: CoverImage, points: CGFloat) -> NSImage? {
        let pixels = bucket(points)
        let key = "\(cover.path)#\(cover.bytes)#\(cover.width)x\(cover.height)@\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(cover.url as CFURL, nil),
              let image = downsample(source, maxPixels: pixels) else { return nil }
        cache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    static func image(for url: URL, data: Data, points: CGFloat) -> NSImage? {
        let pixels = bucket(points)
        let key = "\(url.absoluteString)@\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsample(source, maxPixels: pixels) else { return nil }
        cache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    static func cached(_ url: URL, points: CGFloat) -> NSImage? {
        cache.object(forKey: "\(url.absoluteString)@\(bucket(points))" as NSString)
    }

    /// Retina pixels rounded up to a power of two, so nearby sizes share one decoded image.
    private static func bucket(_ points: CGFloat) -> Int {
        let needed = max(32, Int((points * 2).rounded(.up)))
        var size = 32
        while size < needed { size *= 2 }
        return size
    }

    private static func downsample(_ source: CGImageSource, maxPixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func cost(of image: NSImage) -> Int {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}

/// Poster from the web, downloaded once per URL and decoded at the shown size (replaces AsyncImage,
/// which reloads and decodes the full image every time a row is recreated).
struct RemoteImage<Placeholder: View>: View {
    let url: URL
    let points: CGFloat
    var fill = false
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewState private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? CoverCache.cached(url, points: points) {
                if fill {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if CoverCache.cached(url, points: points) != nil { return }
            guard let data = await RemoteImageLoader.shared.data(for: url) else { return }
            image = CoverCache.image(for: url, data: data, points: points)
        }
    }
}

/// Downloads each URL once, even when several views ask for it at the same time.
actor RemoteImageLoader {
    static let shared = RemoteImageLoader()
    private var running: [URL: Task<Data?, Never>] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func data(for url: URL) async -> Data? {
        if let task = running[url] { return await task.value }
        let session = session
        let task = Task<Data?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
            return data
        }
        running[url] = task
        let data = await task.value
        running[url] = nil
        return data
    }
}

/// Text field that edits a local copy and commits on Return or when it loses focus.
/// Used in table cells, where committing every keystroke would redraw the row while typing.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    init(_ title: String, value: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.commit = commit
    }

    var body: some View {
        TextField(title, text: $text)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onSubmit(save)
    }

    private func save() {
        if text != value { commit(text) }
    }
}
