#if os(iOS)
import SwiftUI
import Perception

/// Fields use the panel's own foreground and a shallow, translucent inset.
@MainActor struct LocalGlassTextFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .padding(.horizontal, 12).padding(.vertical, 10)
            .localGlassInputSurface()
            .tint(.accentColor)
    }
}

/// Raised glass actions keep a fixed readable foreground in both appearances.
struct LocalGlassButtonStyle: ButtonStyle {
    var prominent = false
    var wrapsLabel = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(wrapsLabel ? nil : 1)
            .fixedSize(horizontal: !wrapsLabel, vertical: wrapsLabel)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                shape.fill(prominent ? Color(uiColor: .systemBlue) :
                            Color.white.opacity(scheme == .dark ? 0.10 : 0.48))
                    .overlay {
                        shape.fill(LinearGradient(colors: [.white.opacity(configuration.isPressed ? 0.02 : 0.16), .clear],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.08), radius: 3, x: 1, y: 2)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.55), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.80 : 1) : 0.46)
    }
}

struct LocalGlassChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
    init(_ value: Value, _ title: String) { self.value = value; self.title = title }
}

/// Expands inside the current panel so options retain its material, contrast and
/// touch targets. Long lists scroll independently and can be searched.
struct LocalGlassChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [LocalGlassChoice<Value>]
    var showsTitle = true
    @State private var expanded = false
    @State private var query = ""
    @Environment(\.isEnabled) private var enabled

    private var selectedTitle: String { options.first { $0.value == selection }?.title ?? "未选择" }
    private var visibleOptions: [LocalGlassChoice<Value>] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? options : options.filter { $0.title.localizedStandardContains(text) }
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expanded.toggle()
                    if !expanded { query = "" }
                } label: {
                    HStack(spacing: 10) {
                        if showsTitle { Text(title).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text(selectedTitle).multilineTextAlignment(.trailing)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .localGlassInputSurface()
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title).accessibilityValue(selectedTitle)
                .accessibilityHint(expanded ? "收起选项" : "展开选项")
                .opacity(enabled ? 1 : 0.45)
                if expanded {
                    VStack(spacing: 4) {
                        if options.count > 12 {
                            TextField("搜索" + title, text: $query)
                                .textFieldStyle(LocalGlassTextFieldStyle())
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(visibleOptions) { option in
                                    Button {
                                        selection = option.value
                                        expanded = false; query = ""
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(option.title).frame(maxWidth: .infinity, alignment: .leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Image(systemName: "checkmark")
                                                .font(.subheadline.weight(.semibold))
                                                .opacity(selection == option.value ? 1 : 0)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .background(selection == option.value ? Color.accentColor.opacity(0.18) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 10))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selection == option.value ? [.isSelected] : [])
                                }
                                if visibleOptions.isEmpty {
                                    Text("没有匹配选项").foregroundStyle(.secondary).padding(12)
                                }
                            }
                        }
                        // Cap fits six rows (6 * 48) so short lists — e.g. the
                        // five danmaku colour modes — expand fully visible and
                        // tappable; longer lists keep scrolling under the cap.
                        .frame(height: min(288, CGFloat(max(1, visibleOptions.count)) * 48))
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .padding(6).localGlassInputSurface()
                }
            }
        }
    }
}
#endif
