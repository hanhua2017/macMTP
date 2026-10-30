import SwiftUI

struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("autoDetectDevice") private var autoDetectDevice: Bool = true
    @AppStorage("swapPanels") private var swapPanels: Bool = false
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.system.rawValue

    var body: some View {
        ScrollView {
            Form {
                Section(header: Text("General").font(.headline)) {
                    Picker("Language", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.localizedTitle).tag(language.rawValue)
                        }
                    }
                    .onChange(of: appLanguage) { _, _ in
                        UserDefaults.standard.synchronize()
                        NotificationCenter.default.post(name: L10n.languageDidChange, object: nil)
                    }

                    Toggle("Auto-detect and connect MTP device on launch", isOn: $autoDetectDevice)
                }
                .padding(.bottom, 10)

                Section(header: Text("File Explorer").font(.headline)) {
                    Toggle("Show hidden files on Local Mac", isOn: $showHiddenFilesLocal)
                    Toggle("Show hidden files on Android Device", isOn: $showHiddenFilesMTP)
                    Toggle("Swap Local and MTP panels (MTP on Left)", isOn: $swapPanels)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.f("Font Size Scale: %.1fx", appFontScale))
                            Spacer()
                            Button("Reset") {
                                appFontScale = 1.0
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        }
                        Slider(value: $appFontScale, in: 0.7...2.0, step: 0.1)
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 10)


            }
            .padding(20)
        }
        .frame(width: 480)
    }
}
