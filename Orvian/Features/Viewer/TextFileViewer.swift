import SwiftUI
import SafariServices

/// Visionneuse de fichiers texte (.txt).
///
/// Mode lecture par défaut : les liens sont surlignés et cliquables
/// (ouverture dans un navigateur Safari intégré à l'app). Un bouton crayon
/// dans la barre d'outils passe en mode modification ; « Terminé » remplace
/// le contenu du fichier côté kDrive (nouvelle version via `file_id`). Une
/// marge en bas permet de faire défiler le texte au-dessus du clavier pendant
/// l'édition.
struct TextFileViewer: View {
    let file: DriveFile
    let driveId: Int

    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var saveError: String?
    /// URL ouverte par un tap sur un lien du texte : affichée dans un
    /// `SFSafariViewController` intégré, sans quitter l'app.
    @State private var safariURL: SafariItem?

    private let service = KDriveService()

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Impossible d'ouvrir le fichier",
                        systemImage: "doc.text",
                        description: Text(loadError)
                    )
                } else if isLoading {
                    ProgressView("Chargement…")
                } else if isEditing {
                    editor
                } else {
                    reader
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isLoading && loadError == nil {
                        if isEditing {
                            Button("Annuler") {
                                draft = content
                                isEditing = false
                            }
                            .disabled(isSaving)
                            Button {
                                Task { await save() }
                            } label: {
                                if isSaving {
                                    ProgressView()
                                } else {
                                    Text("Terminé")
                                }
                            }
                            .fontWeight(.semibold)
                            .disabled(isSaving)
                        } else {
                            Button {
                                isEditing = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .accessibilityLabel("Modifier le fichier")
                        }
                    }
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                    }
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .task {
            await load()
        }
        .fullScreenCover(item: $safariURL) { item in
            SafariViewController(url: item.url)
                .ignoresSafeArea()
        }
        .alert("Enregistrement impossible", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Lecture

    private var reader: some View {
        ScrollView {
            Text(attributedContent)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .textSelection(.enabled)
        }
        // Un tap sur un lien HTTP(S) ouvre la fenêtre Safari intégrée au lieu
        // de quitter l'app ; les autres liens (mailto:…) suivent le système.
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return .systemAction
            }
            safariURL = SafariItem(url: url)
            return .handled
        })
        // Marge de défilement : la dernière ligne reste atteignable au-dessus
        // du clavier et de la barre flottante de l'app.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
    }

    /// Contenu avec liens détectés (URL, e-mails…) en surbrillance et
    /// cliquables : un tap ouvre la fenêtre Safari intégrée à l'app.
    private var attributedContent: AttributedString {
        var result = AttributedString()
        let nsContent = content as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return AttributedString(content)
        }
        let matches = detector.matches(
            in: content,
            options: [],
            range: NSRange(location: 0, length: nsContent.length)
        )
        var last = 0
        for match in matches {
            let range = match.range
            if range.location > last {
                result += AttributedString(nsContent.substring(with: NSRange(location: last, length: range.location - last)))
            }
            if let url = match.url {
                var link = AttributedString(nsContent.substring(with: range))
                link.link = url
                link.underlineStyle = .single
                result += link
            }
            last = range.location + range.length
        }
        if last < nsContent.length {
            result += AttributedString(nsContent.substring(with: NSRange(location: last, length: nsContent.length - last)))
        }
        return result
    }

    // MARK: - Modification

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled(false)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            // Marge sous la dernière ligne : on peut faire défiler le texte
            // au-dessus du clavier pour modifier ou ajouter des lignes en bas.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 160)
            }
    }

    // MARK: - Données

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
                throw NSError(
                    domain: "TextFileViewer",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Impossible d'obtenir le lien du fichier."]
                )
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            content = Self.decode(data) ?? ""
            draft = content
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let data = Data(draft.utf8)
            try await service.uploadContent(driveId: driveId, fileId: file.id, data: data)
            content = draft
            isEditing = false
        } catch {
            saveError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// UTF-8 d'abord, puis Windows-1252 (accentués courants), Latin-1 en
    /// dernier recours : les .txt existants ne sont pas tous en UTF-8.
    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }
}

/// Cible de présentation d'une URL dans la fenêtre Safari intégrée.
private struct SafariItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Fenêtre Safari intégrée à l'app (barre d'outils Safari, bouton Terminé,
/// partage…). Les liens restent ainsi dans l'app au lieu d'ouvrir Safari.
private struct SafariViewController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}