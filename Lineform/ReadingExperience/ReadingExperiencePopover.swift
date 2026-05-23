import SwiftUI

struct ReadingExperiencePopover: View {
    @ObservedObject var store: ReadingProfileStore

    var body: some View {
        Form {
            Picker("Preset", selection: presetSelection) {
                ForEach(ReadingPreset.builtIn) { preset in
                    Text(preset.profile.name).tag(preset.profile.id)
                }
            }

            Picker("Font", selection: fontSelection) {
                ForEach(FontOption.groupedOptions) { group in
                    Section(group.name) {
                        ForEach(group.options) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
            }

            Slider(value: numericBinding(\.fontSize, range: 13...28), in: 13...28) {
                Text("Font Size")
            }

            Slider(value: numericBinding(\.lineHeightMultiple, range: 1.1...1.8), in: 1.1...1.8) {
                Text("Line Height")
            }

            Slider(value: numericBinding(\.paragraphSpacing, range: 0...24), in: 0...24) {
                Text("Paragraph Spacing")
            }

            Slider(value: numericBinding(\.letterSpacing, range: 0...1.2), in: 0...1.2) {
                Text("Letter Spacing")
            }

            Slider(value: numericBinding(\.columnWidth, range: 460...900), in: 460...900) {
                Text("Column Width")
            }

            Slider(value: numericBinding(\.marginWidth, range: 20...120), in: 20...120) {
                Text("Margins")
            }

            Toggle("Reduce Markdown Noise", isOn: boolBinding(\.reduceMarkdownNoise))
        }
        .formStyle(.grouped)
        .padding(14)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reading Experience")
    }

    private var presetSelection: Binding<UUID> {
        Binding(
            get: { store.activeProfile.id },
            set: { id in
                guard let preset = ReadingPreset.builtIn.first(where: { $0.profile.id == id }) else {
                    return
                }
                store.apply(preset.profile)
            }
        )
    }

    private var fontSelection: Binding<FontID> {
        Binding(
            get: { store.activeProfile.fontID },
            set: { fontID in
                store.update { $0.fontID = fontID }
            }
        )
    }

    private func numericBinding(_ keyPath: WritableKeyPath<ReadingProfile, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { store.activeProfile[keyPath: keyPath] },
            set: { value in
                store.update { $0[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound) }
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<ReadingProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.activeProfile[keyPath: keyPath] },
            set: { value in
                store.update { $0[keyPath: keyPath] = value }
            }
        )
    }
}
