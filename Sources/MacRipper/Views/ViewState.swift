import SwiftUI

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

/// Decoded cover images, so lists that redraw every second do not read files from disk each time.
enum CoverCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()

    /// The key includes size and byte count: a replaced cover reuses the same file name.
    static func image(for cover: CoverImage) -> NSImage? {
        let key = "\(cover.path)#\(cover.bytes)#\(cover.width)x\(cover.height)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = NSImage(contentsOf: cover.url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
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
