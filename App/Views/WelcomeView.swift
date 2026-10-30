import SwiftUI

struct WelcomeView: View {
    var recentDocuments: [URL] = []
    let open: () -> Void
    let liveStreaming: () -> Void
    var openRecent: (URL) -> Void = { _ in }
    var tour: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if geometry.size.width >= 720 {
                        HStack(alignment: .top, spacing: 36) {
                            introduction.frame(width: 250)
                            recents
                        }
                    } else {
                        VStack(spacing: 28) { introduction; recents }
                    }
                }
                .padding(32).frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
        }
    }

    private var introduction: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(verbatim: "Margined").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text("Read, review, listen.").font(.title3).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                Button("Open Markdown…", action: open).buttonStyle(.borderedProminent).keyboardShortcut("o")
                Button("Live Streaming Preview", action: liveStreaming).buttonStyle(.bordered)
                Button("Take a Tour", action: tour).buttonStyle(.link)
            }.controlSize(.large)
        }.multilineTextAlignment(.center)
    }

    private var recents: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Documents").font(.headline).accessibilityAddTraits(.isHeader)
                if recentDocuments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Recent Documents").font(.callout.weight(.medium))
                        Text("Open a Markdown document to get started.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 28)
                } else {
                    ForEach(Array(recentDocuments.prefix(10)), id: \.self) { url in
                        Button { openRecent(url) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text").font(.title3).foregroundStyle(.tint).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                                    Text(verbatim: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                            }.padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(url.path)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
