import SwiftUI

struct SubtitleSettingsView: View {
    @AppStorage(SubtitleSettings.modeKey) private var preferredMode: SubtitleMode = .off
    @AppStorage(SubtitleSettings.sourceKey) private var source: SubtitleSourceLanguage = .english
    @AppStorage(SubtitleSettings.fontSizeKey) private var fontSize = SubtitleSettings.defaultFontSize
    @AppStorage(SubtitleSettings.backgroundOpacityKey) private var opacity = SubtitleSettings.defaultBackgroundOpacity
    @AppStorage(SubtitleSettings.displayDurationKey) private var duration = SubtitleSettings.defaultDisplayDuration

    var body: some View {
        List {
            Section {
                Picker("Mode préféré", selection: $preferredMode) {
                    ForEach(SubtitleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Langue parlée dans la vidéo", selection: $source) {
                    ForEach(SubtitleSourceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
            } header: {
                Text("Langues")
            } footer: {
                Text("Ces choix sont conservés pour les prochaines vidéos. Le menu CC du lecteur permet aussi de les modifier. En mode français, aucun texte original n’est affiché en attendant la traduction.")
            }

            Section("Affichage") {
                VStack(alignment: .leading) {
                    Text("Taille du texte : \(Int(SubtitleSettings.fontSize(fontSize))) pt")
                    Slider(value: $fontSize, in: 14...28, step: 1) {
                        Text("Taille du texte")
                    }
                }
                VStack(alignment: .leading) {
                    Text("Opacité du fond : \(Int(SubtitleSettings.backgroundOpacity(opacity) * 100)) %")
                    Slider(value: $opacity, in: 0.6...0.95, step: 0.05) {
                        Text("Opacité du fond")
                    }
                }
                VStack(alignment: .leading) {
                    Text("Durée maximale d’affichage : \(Int(SubtitleSettings.displayDuration(duration))) s")
                    Slider(value: $duration, in: 3...10, step: 1) {
                        Text("Durée maximale d’affichage")
                    }
                    Text("Une nouvelle phrase remplace la précédente dès qu’elle est prête.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Aperçu") {
                Text("Les sous-titres s’afficheront comme ceci.")
                    .font(.system(size: SubtitleSettings.fontSize(fontSize), weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(SubtitleSettings.backgroundOpacity(opacity)),
                                in: RoundedRectangle(cornerRadius: 10))
            }

            Section {
                Button("Rétablir les réglages par défaut") {
                    preferredMode = .off
                    source = .english
                    fontSize = SubtitleSettings.defaultFontSize
                    opacity = SubtitleSettings.defaultBackgroundOpacity
                    duration = SubtitleSettings.defaultDisplayDuration
                }
            } footer: {
                Text("La reconnaissance et la traduction fonctionnent sur l’appareil après le téléchargement éventuel des langues. Sous-titres disponibles à 1×, hors AirPlay, pour les sources audio compatibles.")
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: DS.contentBottomInset)
        }
        .navigationTitle("Sous-titres")
        .navigationBarTitleDisplayMode(.inline)
    }
}
