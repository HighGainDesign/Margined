import SwiftUI

/// One native navigation stack retains its document root while presenting conversations.
struct MobileDocumentWorkspace: View {
    @Bindable var reader: MobileReaderState
    let openFolder: () -> Void
    let closeFile: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        GeometryReader { geometry in
            let fits = !textSize.isAccessibilitySize && DiscussionMarginLayout.canShowMargin(width: geometry.size.width,
                bodyFont: reader.discussionMargin?.bodyFont ?? 16 * reader.zoom,
                horizontalInsets: reader.discussionMargin?.horizontalInsets ?? 48, outlineWidth: 0)
            NavigationStack(path: Binding(get: { reader.discussionUsesMargin ? [] : reader.discussionNavigationPath },
                set: { if !reader.discussionUsesMargin { reader.discussionNavigationPath = $0 } })) {
                MobileReaderView(reader: reader, openFolder: openFolder, closeFile: closeFile)
                    .navigationTitle(reader.title).navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: MobileDiscussionRoute.self) { route in
                        switch route {
                        case .list: MobileDiscussionList(reader: reader)
                        case .thread(let key): MobileDiscussionThread(reader: reader, key: key)
                        }
                    }
            }
            .onChange(of: fits, initial: true) { _, value in reader.discussionUsesMargin = value }
            .overlay {
                MobileDiscussionFilePickerPresenter(reader: reader).frame(width: 0, height: 0)
                if let sheet = reader.discussionSheet { MobileDiscussionSheetPresenter(reader: reader, sheet: sheet).id(sheet.id) }
            }
        }
    }
}
