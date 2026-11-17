#if !os(tvOS)
import SwiftUI
import Perception
import TVCore

struct EpisodeSkipSettingsView: View {
    let session: PlaybackSession
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var intro = ""
    @State private var outro = ""

    private var draft: EpisodeSkipSettings? {
        guard let introEnd = intro.isEmpty ? 0 : EpisodeSkipSettings.parseTime(intro),
              let outroStart = outro.isEmpty ? session.duration : EpisodeSkipSettings.parseTime(outro),
              outroStart <= session.duration else { return nil }
        return EpisodeSkipSettings(enabled: enabled, introEnd: introEnd,
                                   outroLength: outro.isEmpty ? 0 : session.duration - outroStart)
    }
    private var issue: String? {
        guard let draft else { return L10n.text("Enter a valid time such as 01:30.") }
        return draft.validationError(duration: session.duration)
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                WithPerceptionTracking {
                    Form {
                        Section {
                            Toggle(L10n.text("Automatically skip intro and outro"), isOn: $enabled)
                                .settingsSwitch()
                                .accessibilityIdentifier("player.skip.enabled")
                            Text(L10n.text("Times apply to this series and all its episodes. Automatic skipping is a global switch. The outro is remembered as time remaining."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        #if os(iOS)
                        Section("匹配结果") {
                            Text(session.remoteSkip.status.isEmpty ? "等待视频信息" : session.remoteSkip.status)
                                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("player.skip.remoteStatus")
                            ForEach(Array(session.remoteSkip.segments.enumerated()), id: \.offset) { _, segment in
                                LabeledContent(segment.kind == "opening" ? "片头" : "片尾") {
                                    Text(EpisodeSkipSettings.formatTime(segment.start) + "–" + EpisodeSkipSettings.formatTime(segment.end) + " · " + segment.source)
                                        .font(.footnote)
                                }
                            }
                        }
                        #endif
                        Section(L10n.text("Intro ends at")) {
                            timeField(L10n.text("Intro ends at"), text: $intro, identifier: "player.skip.intro")
                            Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.position))) {
                                intro = EpisodeSkipSettings.formatTime(session.position); enabled = true
                            }.disabled(session.duration < 120)
                            .accessibilityIdentifier("player.skip.markIntro")
                            #if os(iOS)
                            Button("片头恢复自动匹配") { intro = "" }
                                .accessibilityIdentifier("player.skip.resetIntro")
                            #endif
                        }
                        Section(L10n.text("Outro starts at")) {
                            timeField(L10n.text("Outro starts at"), text: $outro, identifier: "player.skip.outro")
                            Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.position))) {
                                outro = EpisodeSkipSettings.formatTime(session.position); enabled = true
                            }.disabled(session.duration < 120)
                            .accessibilityIdentifier("player.skip.markOutro")
                            #if os(iOS)
                            Button("片尾恢复自动匹配") { outro = "" }
                                .accessibilityIdentifier("player.skip.resetOutro")
                            #endif
                            #if os(iOS)
                            Text("留空采用章节或远程匹配；手动记录优先。时间格式：分:秒。")
                                .font(.footnote).foregroundStyle(.secondary)
                            #else
                            Text(L10n.text("Leave a time empty to keep that segment. Format: minutes:seconds."))
                                .font(.footnote).foregroundStyle(.secondary)
                            #endif
                        }
                        if let issue {
                            Section { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("player.skip.validation") }
                        }
                        Section {
                            Button(L10n.text("Reset intro and outro"), role: .destructive) {
                                enabled = false; intro = ""; outro = ""
                            }
                        }
                    }
                    .navigationTitle(L10n.text("Skip intro / outro"))
                    .toolbar { WithPerceptionTracking {

                            ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.text("Save")) {
                                    if let draft { session.applySkipSettings(draft); dismiss() }
                                }
                                .disabled(draft == nil || (enabled && issue != nil))
                                .accessibilityIdentifier("player.skip.save")
                            }

                     }}
                }
            }
            .onAppear {
                #if os(iOS)
                session.remoteSkip.requestMatch()
                #endif
                session.beginEditingSkip()
                let value = session.skipSettings
                enabled = value.enabled
                intro = value.introEnd > 0 ? EpisodeSkipSettings.formatTime(value.introEnd) : ""
                outro = value.outroLength > 0 ? EpisodeSkipSettings.formatTime(max(0, session.duration - value.outroLength)) : ""
            }
            .onDisappear { session.endEditingSkip() }
            #if os(macOS)
            .frame(width: 500, height: 570)
            #else
            .presentationDetents([.large])
            #endif
        }
    }

    private func timeField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        TextField(title, text: text, prompt: Text("01:30"))
            .monospacedDigit()
            .accessibilityIdentifier(identifier)
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }
}
#endif
