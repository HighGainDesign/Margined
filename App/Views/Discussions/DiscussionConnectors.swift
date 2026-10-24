import SwiftUI

struct DiscussionConnectors: View {
    let reader: ReaderState
    let frames: [String: CGRect]
    let aligned: Bool
    var body: some View {
        Canvas { context, size in
            guard aligned else { return }
            for anchor in reader.discussionMargin?.anchors ?? [] {
                let y = anchor.top * reader.zoom
                guard y >= 0, y <= size.height, let card = frames["t:" + anchor.id],
                      card.minY < size.height, card.maxY > 0 else { continue }
                let selected = reader.discussions.selection == .thread(anchor.id)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: 5, y: y))
                path.addLine(to: CGPoint(x: max(5, card.minX - 4), y: card.minY + 24))
                path.addLine(to: CGPoint(x: card.minX, y: card.minY + 24))
                context.stroke(path, with: .color(selected ? .accentColor : .secondary.opacity(0.5)), lineWidth: selected ? 1.5 : 1)
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
