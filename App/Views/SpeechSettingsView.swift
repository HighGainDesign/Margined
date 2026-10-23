import SwiftUI
import AVFAudio

struct SpeechSettingsView: View {
    @Bindable var preferences: SpeechPreferences
    @State private var voiceLanguage = Self.initialLanguage
    @State private var voices: [SpeechVoice] = []
    @State private var historyCleared = false

    init(preferences: SpeechPreferences = .shared) { self.preferences = preferences }

    var body: some View {
        Form {
            Section {
                HStack {
                    Slider(value: $preferences.rate, in: 0.5...2, step: 0.05) { Text("Reading speed") }
                    Text("\(preferences.rate.formatted(.number.precision(.fractionLength(0...2))))×")
                        .monospacedDigit().frame(width: 54, alignment: .trailing)
                }
                Toggle("Follow the current paragraph", isOn: $preferences.followReading)
                Toggle("Read code blocks", isOn: $preferences.options.includeCode)
                Toggle("Read link destinations", isOn: $preferences.options.includeLinkDestinations)
            } header: { Text("Reading defaults") }
            footer: { Text("These defaults apply when you start Read Aloud. You can change speed, voice and Follow Reading in the player.") }
            Section {
                Picker("Voice language", selection: $voiceLanguage) {
                    ForEach(DocumentLanguage.menuCodes, id: \.self) { code in Text(DocumentLanguage.displayName(code)).tag(code) }
                }
                Picker("Preferred voice", selection: Binding(get: { preferences.voice(for: voiceLanguage) },
                                                            set: { preferences.setVoice($0, for: voiceLanguage) })) {
                    Text("Automatic").tag(Optional<String>.none)
                    ForEach(matchingVoices) { voice in Text("\(voice.name) · \(voice.language)").tag(Optional(voice.id)) }
                }
                Toggle("Use VoiceOver Speech Settings", isOn: $preferences.useAssistiveTechnologySettings)
                    .help("When VoiceOver is on, use its voice and speed instead of the choices here.")
                Button("Open Accessibility Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") { NSWorkspace.shared.open(url) }
                }
            } header: { Text("System voices") }
            footer: { Text("Voices are provided by macOS. Add more in Accessibility settings. Document language is detected or chosen in Reading options; it is independent of the interface language.") }
            Section {
                Button("Clear Reading History", role: .destructive) {
                    SpeechProgressStore().clear(); preferences.historyRevision += 1; historyCleared = true
                }.help("Remove saved listening positions. Markdown files stay unchanged.")
                if historyCleared { Label("Reading history cleared", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            } header: { Text("Saved positions") }
            footer: { Text("Margined remembers positions in saved files using content hashes and offsets. It does not save document text or live streams in reading history.") }
        }
        .formStyle(.grouped)
        .task { voices = SystemSpeechDriver.availableVoices() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices = SystemSpeechDriver.availableVoices()
        }
    }
    private var matchingVoices: [SpeechVoice] {
        let base = voiceLanguage.split(separator: "-").first
        return voices.filter { $0.language.split(separator: "-").first == base }
    }
    private static var initialLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        if code == "zh" { return Locale.current.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
        return DocumentLanguage.menuCodes.contains(code) ? code : "en"
    }
}
