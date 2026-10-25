import SwiftUI
import UIKit

struct AppearanceView: View {
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var iconError: String?

    var body: some View {
        @Bindable var theme = Theme.shared
        List {
            Section("Accent color") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 14)], spacing: 14) {
                    ForEach(Theme.presets, id: \.hex) { preset in
                        let selected = theme.accentHex.uppercased() == preset.hex
                        Button { theme.accentHex = preset.hex } label: {
                            Circle().fill(Color(hex: preset.hex)!)
                                .frame(width: 44, height: 44)
                                .overlay { if selected { Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.black) } }
                                .overlay(Circle().stroke(Color.white, lineWidth: selected ? 2 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(preset.name))
                    }
                }
                .padding(.vertical, 6)
                ColorPicker("Custom color", selection: Binding(get: { theme.accent }, set: { theme.accentHex = $0.hex }), supportsOpacity: false)
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 16) {
                    ForEach(AppIconChoice.all) { choice in
                        Button { setIcon(choice.id) } label: {
                            VStack(spacing: 6) {
                                IconPreview(choice: choice)
                                    .overlay(alignment: .bottomTrailing) {
                                        if choice.id == currentIcon {
                                            Image(systemName: "checkmark.circle.fill").font(.title3)
                                                .foregroundStyle(.white, Color.accent).offset(x: 6, y: 6)
                                        }
                                    }
                                Text(choice.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("App icon")
            } footer: {
                if let iconError { Text(iconError).foregroundStyle(.red) }
            }

            Section {
                Toggle("Tint backgrounds with cover colors", isOn: $theme.coverTint)
                Toggle("Show lyrics first in the player", isOn: $theme.lyricsFirst)
                Picker("Start screen", selection: $theme.startTab) {
                    Text("Home").tag(0)
                    Text("Search").tag(1)
                    Text("Library").tag(2)
                }
            } header: { Text("Behavior") }

            Section("Home screen rows") {
                ForEach(Theme.homeRows, id: \.id) { row in
                    Toggle(isOn: Binding(
                        get: { !theme.hiddenHomeRows.contains(row.id) },
                        set: { show in if show { theme.hiddenHomeRows.remove(row.id) } else { theme.hiddenHomeRows.insert(row.id) } }
                    )) { Text(row.name) }
                }
            }

            Section {
                Button("Reset to defaults", role: .destructive) {
                    theme.accentHex = Theme.defaultAccent
                    theme.coverTint = true
                    theme.lyricsFirst = false
                    theme.startTab = 0
                    theme.hiddenHomeRows = []
                    setIcon(nil)
                }
            }
        }
        .navigationTitle("Appearance")
    }

    private func setIcon(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons, name != UIApplication.shared.alternateIconName else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            Task { @MainActor in
                if let error { iconError = error.localizedDescription } else { iconError = nil; currentIcon = name }
            }
        }
    }
}
