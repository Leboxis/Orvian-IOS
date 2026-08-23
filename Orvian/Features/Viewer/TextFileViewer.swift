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
    @State private var showCloseConfirmation = false
    /// Contenu avec liens déjà détectés : construit une seule fois par
    /// changement de contenu au lieu d'être recalculé à chaque rendu.
    @State private var attributedContent = AttributedString("")
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
                                Task { _ = await save() }
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
                        requestDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                    }
                    .disabled(isSaving)
                    .accessibilityLabel("Fermer")
                }
            }
        }
        .task {
            await load()
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .fullScreenCover(item: $safariURL) { item in
            SafariViewController(url: item.url)
                .ignoresSafeArea()
        }
        .alert("Enregistrement impossible", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog(
            "Enregistrer les modifications ?",
            isPresented: $showCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enregistrer et fermer") {
                Task {
                    if await save() {
                        dismiss()
                    }
                }
            }
            Button("Abandonner les modifications", role: .destructive) {
                dismiss()
            }
            Button("Continuer la modification", role: .cancel) {}
        } message: {
            Text("Le brouillon n’a pas encore été enregistré dans kDrive.")
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

    /// Liens (URL, e-mails…) surlignés et cliquables : un tap ouvre la
    /// fenêtre Safari intégrée à l'app. La détection est faite une fois par
    /// contenu, hors thread principal — la version précédente relançait
    /// `NSDataDetector` sur tout le fichier à chaque rendu de la vue.
    private static func attributedText(for content: String) async -> AttributedString {
        await Task.detached(priority: .userInitiated) { () -> AttributedString in
            guard let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            ) else {
                return AttributedString(content)
            }
            var result = AttributedString()
            let nsContent = content as NSString
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
        }.value
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

    /// `TextEditor` et la détection des liens du lecteur travaillent sur une
    /// chaîne complète en mémoire. Au-delà de cette limite, ouvrir le fichier
    /// ferait courir un risque de forte pression mémoire, notamment dans
    /// LiveContainer.
    private static let maximumEditableBytes = 5 * 1_024 * 1_024

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let size = file.size, size > Self.maximumEditableBytes {
                throw TextFileViewerError.tooLarge(maximumBytes: Self.maximumEditableBytes)
            }
            guard let url = await MediaURLCache.shared.url(driveId: driveId, fileId: file.id) else {
                throw TextFileViewerError.missingTemporaryURL
            }
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw TextFileViewerError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw TextFileViewerError.http(status: http.statusCode)
            }
            if http.expectedContentLength > Int64(Self.maximumEditableBytes) {
                throw TextFileViewerError.tooLarge(maximumBytes: Self.maximumEditableBytes)
            }

            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(Int(http.expectedContentLength), Self.maximumEditableBytes))
            }
            for try await byte in bytes {
                guard data.count < Self.maximumEditableBytes else {
                    throw TextFileViewerError.tooLarge(maximumBytes: Self.maximumEditableBytes)
                }
                data.append(byte)
            }
            guard let decoded = Self.decode(data) else {
                throw TextFileViewerError.unsupportedEncoding
            }
            let attributed = await Self.attributedText(for: decoded)
            content = decoded
            draft = decoded
            attributedContent = attributed
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    private func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let data = Data(draft.utf8)
            guard data.count <= Self.maximumEditableBytes else {
                throw TextFileViewerError.tooLarge(maximumBytes: Self.maximumEditableBytes)
            }
            try await service.uploadContent(driveId: driveId, fileId: file.id, data: data)
            await MediaURLCache.shared.invalidate(driveId: driveId, fileId: file.id)
            let attributed = await Self.attributedText(for: draft)
            content = draft
            attributedContent = attributed
            isEditing = false
            return true
        } catch {
            saveError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// UTF-8 d'abord, puis Windows-1252 (accentués courants), Latin-1 en
    /// dernier recours : les .txt existants ne sont pas tous en UTF-8.
    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    private var hasUnsavedChanges: Bool {
        isEditing && draft != content
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showCloseConfirmation = true
        } else {
            dismiss()
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }
}

private enum TextFileViewerError: LocalizedError {
    case missingTemporaryURL
    case invalidResponse
    case http(status: Int)
    case tooLarge(maximumBytes: Int)
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .missingTemporaryURL:
            return "Impossible d’obtenir le lien du fichier."
        case .invalidResponse:
            return "Le serveur a renvoyé une réponse invalide."
        case let .http(status):
            return "Le fichier n’a pas été téléchargé (HTTP \(status))."
        case let .tooLarge(maximumBytes):
            return "Ce fichier est trop volumineux pour l’éditeur. La limite est de \(ByteFormatter.format(maximumBytes))."
        case .unsupportedEncoding:
            return "L’encodage de ce fichier texte n’est pas pris en charge."
        }
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
