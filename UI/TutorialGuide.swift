import SwiftUI

struct TutorialGuide<Actions: View, Footer: View>: View {
    @Bindable var session: TutorialSession
    let done: () -> Void
    let openPractice: (TutorialLesson) -> Void
    @ViewBuilder var actions: (TutorialLesson) -> Actions
    @ViewBuilder var footer: () -> Footer
    private var lessons: [TutorialLesson] { TutorialLesson.lessons(for: session.platform) }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $session.selection) {
                    Section {
                        Text("Choose a lesson. Practice copies are disposable; your own files stay unchanged.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Section {
                        ForEach(lessons) { lesson in
                            NavigationLink(value: lesson) { Label(lesson.title, systemImage: lesson.symbol) }
                                .tag(lesson)
                        }
                    }
                }
                .navigationTitle("Take a Tour")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
            } detail: {
                if let lesson = session.selection {
                    detail(lesson)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "book.pages").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                        Text("Read, review, discuss.").font(.title.bold()).accessibilityAddTraits(.isHeader)
                        Text("Choose a lesson. Practice copies are disposable; your own files stay unchanged.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Take a Tour") { session.selection = .opening }.buttonStyle(.borderedProminent)
                    }.padding(28).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { footer(); Spacer(minLength: 12); doneButton }
                VStack(alignment: .leading, spacing: 12) { footer(); HStack { Spacer(); doneButton } }
            }.padding(16).background(.bar)
        }
    }
    private var doneButton: some View {
        Button("Done", action: done).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
    }

    private func detail(_ lesson: TutorialLesson) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(lesson.title, systemImage: lesson.symbol).font(.title.bold()).accessibilityAddTraits(.isHeader)
                Text(lesson.explanation(for: session.platform)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                actions(lesson)
                if lesson != .streaming {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open Practice Document") { openPractice(lesson) }
                            .buttonStyle(.borderedProminent).disabled(session.preparing)
                        Text("A fresh disposable copy opens in the reader.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = session.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                }
                Divider()
                HStack {
                    if let index = lessons.firstIndex(of: lesson), index > 0 {
                        Button("Previous") { session.selection = lessons[index - 1] }
                    }
                    Spacer()
                    if let index = lessons.firstIndex(of: lesson), index + 1 < lessons.count {
                        Button("Next") { session.selection = lessons[index + 1] }
                    }
                }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle(lesson.title)
    }
}

/// Shown only for files registered by this app's active tutorial session.
struct TutorialPracticeBar: View {
    @Bindable var session: TutorialSession
    let practice: TutorialPractice
    let tour: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading, spacing: 8) { controls }
            }
            if let error = session.error(for: practice.url) {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
    @ViewBuilder private var controls: some View {
        Button("Back to Tour", action: tour).buttonStyle(.bordered)
        if practice.lesson == .changes {
            if session.didUpdate(practice.url) {
                Label("Example change saved", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Save Example Change") { Task { await session.saveExampleChange(for: practice.url) } }
                    .buttonStyle(.borderedProminent).disabled(session.applying)
            }
        }
    }
}
