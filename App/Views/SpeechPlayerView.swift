import SwiftUI

struct SpeechPlayerView: View {
    let reader: ReaderState
    @Bindable var speech: ReaderSpeech

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "headphones").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if speech.conversationID != nil {
                            if speech.session.isActive { Text("Reading Conversation") }
                            else { Text("Read Conversation") }
                        }
                        else { Text("Read Aloud") }
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(sectionTitle).font(.callout.weight(.medium)).lineLimit(1).help(sectionTitle)
                }
                Spacer(minLength: 8)
                Menu {
                    if speech.conversationID != nil { Button("Resume Document") { speech.resumeSaved() }; Divider() }
                    Button("From the Beginning") { speech.requestStart(.beginning) }
                    Button("From Current Section") { speech.requestStart(.visible) }
                    Button("From Selection") { speech.requestStart(.selection) }
                    if speech.bookmark != nil { Button("Resume Saved Position") { speech.resumeSaved() } }
                    Divider()
                    Toggle("Follow Reading", isOn: Binding(get: { speech.session.followReading }, set: { speech.setFollowReading($0) }))
                    Button("Read Aloud Settings…") { (NSApp.delegate as? AppDelegate)?.openSpeechSettings() }
                } label: { Label("Start From", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .fixedSize().help("Choose a reading start point")
                Button { speech.close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).accessibilityLabel("Close Read Aloud").help("Close and stop reading")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { transport; Spacer(minLength: 12); options }
                HStack(spacing: 12) {
                    transport; Spacer(minLength: 8)
                    Menu {
                        Menu("Reading speed") {
                            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { value in
                                Button("\(value.formatted())×") { speech.setRate(value) }
                            }
                        }
                        voiceChoices
                    } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Reading playback options").help("Voice and reading speed")
                }
            }
            if let notice = speech.message ?? speech.session.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
        .accessibilityElement(children: .contain).accessibilityIdentifier("speech-player")
    }

    private var sectionTitle: String {
        speech.session.document?.section(at: speech.session.currentIndex)?.title ?? reader.title
    }
    private var transport: some View {
        HStack(spacing: 8) {
            Button { speech.session.previousSection() } label: { Image(systemName: "backward.end.fill").frame(width: 24, height: 22) }
                .disabled(!speech.session.isActive).accessibilityLabel("Previous section").help("Previous section")
            Button { speech.togglePlayback() } label: {
                Label(speech.session.status == .playing ? "Pause" : "Play", systemImage: speech.session.status == .playing ? "pause.fill" : "play.fill")
                    .frame(minWidth: 62)
            }.buttonStyle(.borderedProminent)
                .disabled(reader.isRendering || reader.checklistSaving || reader.showChecklistConfirmation)
                .accessibilityLabel(speech.session.status == .playing ? "Pause reading" : "Play reading")
            Button { speech.session.nextSection() } label: { Image(systemName: "forward.end.fill").frame(width: 24, height: 22) }
                .disabled(!speech.session.isActive).accessibilityLabel("Next section").help("Next section")
            Button("Stop", systemImage: "stop.fill") { speech.stop() }.disabled(!speech.session.isActive && !speech.isPreparing)
        }.buttonStyle(.bordered).fixedSize()
    }
    private var options: some View {
        HStack(spacing: 12) {
            Picker("Speed", selection: Binding(get: { speech.session.rate }, set: { speech.setRate($0) })) {
                ForEach(Array(Set([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, speech.session.rate])).sorted(), id: \.self) { value in Text("\(value.formatted())×").tag(value) }
            }.labelsHidden().frame(width: 86).accessibilityLabel("Reading speed").help("Reading speed")
            Menu { voiceChoices } label: { Label(speech.session.resolvedVoice?.name ?? String(localized: "Voice"), systemImage: "waveform") }
            .accessibilityLabel("Reading voice").accessibilityValue(speech.session.resolvedVoice?.name ?? String(localized: "Automatic"))
            .lineLimit(1).frame(maxWidth: 180).help("Choose a voice for this document’s language")
        }
    }
    @ViewBuilder private var voiceChoices: some View {
        Button("Automatic Voice") { speech.setVoice(nil) }
        ForEach(languages, id: \.self) { language in
            Menu(Locale.current.localizedString(forIdentifier: language) ?? language) {
                ForEach(speech.session.availableVoices.filter { $0.language == language }) { voice in
                    Button(voice.name) { speech.setVoice(voice.id) }
                }
            }
        }
        Divider()
        Toggle("Use VoiceOver Speech Settings", isOn: Binding(
            get: { speech.preferences.useAssistiveTechnologySettings },
            set: { speech.preferences.useAssistiveTechnologySettings = $0; speech.session.useAssistiveTechnologySettings = $0 }))
    }
    private var languages: [String] { Set(speech.session.availableVoices.map(\.language)).sorted() }
}
