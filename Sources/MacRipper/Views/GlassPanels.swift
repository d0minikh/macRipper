import SwiftUI

/// The right panel: a floating Liquid Glass card over the page, like the queue and lyrics panels in Apple Music.
struct InspectorPanel: View {
    let jobID: UUID?
    static let cornerRadius: CGFloat = 22

    var body: some View {
        Group {
            if let jobID {
                JobInspector(jobID: jobID).id(jobID)
            } else {
                ContentUnavailableView("Nothing to Inspect", systemImage: "sidebar.right",
                                       description: Text("Select a job to see and edit its details."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Forms and lists would otherwise paint an opaque window background over the glass.
        .scrollContentBackground(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
    }
}

/// Background of the page: a soft wash from the artwork (or the disc type's color) at the top. It continues
/// underneath the sidebar, the inspector and the toolbar, so both glass panels visibly float above it.
struct PageBackdrop: View {
    let job: Job?

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            artwork
                .frame(maxWidth: .infinity)
                .frame(height: 460)
                .clipped()
                .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        // Blurred by 80 pt anyway, so a small image looks the same and costs a fraction to decode and blur.
        if let cover = job?.audioInfo?.cover, let image = CoverCache.image(for: cover, points: 128) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 80, opaque: true)
                .opacity(0.5)
        } else if let job, job.discType.isVideo, let url = URL(string: job.posterURL), !job.posterURL.isEmpty {
            RemoteImage(url: url, points: 128, fill: true) { tintWash }
                .blur(radius: 80, opaque: true)
                .opacity(0.45)
        } else {
            tintWash
        }
    }

    private var tintWash: some View {
        LinearGradient(colors: [(job?.discType.tint ?? .accentColor).opacity(0.22), .clear],
                       startPoint: .top, endPoint: .bottom)
    }
}
