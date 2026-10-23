import SwiftUI

struct QuickLookInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if #available(macOS 15, *) {
                instruction(1, String(localized: "Open General → Login Items & Extensions."))
                instruction(2, String(localized: "Choose By Category → Quick Look, then enable Margined."))
            } else {
                instruction(1, String(localized: "Open Privacy & Security → Extensions."))
                instruction(2, String(localized: "Choose Quick Look, then enable Margined."))
            }
            instruction(3, String(localized: "Select a Markdown file in Finder and press Space."))
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.callout).accessibilityElement(children: .combine)
    }
}

struct IntegrationHeading: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
