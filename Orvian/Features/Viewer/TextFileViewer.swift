import SwiftUI
import UIKit
import SafariServices

/// Visionneuse de fichiers texte (.txt).
///
/// Mode lecture par défaut : les liens sont surlignés et cliquables
/// (ouverture dans un navigateur Safari intégré à l'app). Un bouton crayon
/// dans la barre d'outils passe en mode modification ; la validation remplace
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
    @State private var pasteRequest: TextPasteRequest?
    @State private var detectedLinks: [DetectedTextLink] = []
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
                } else {
                    textSurface
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isLoading && loadError == nil {
                        if isEditing {
                            Button {
                                draft = content
                                isEditing = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .disabled(isSaving)
                            .accessibilityLabel("Annuler les modifications")
                            PasteButton(payloadType: String.self) { strings in
                                guard let pastedText = strings.first, !pastedText.isEmpty else { return }
                                pasteRequest = TextPasteRequest(text: pastedText)
                            }
                            .labelStyle(.iconOnly)
                            .disabled(isSaving)
                            .accessibilityLabel("Coller le presse-papiers")
                            Button {
                                Task { _ = await save() }
                            } label: {
                                if isSaving {
                                    ProgressView()
                                } else {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .disabled(isSaving)
                            .accessibilityLabel("Valider les modifications")
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

    // MARK: - Lecture et modification

    private var textSurface: some View {
        TextFileTextView(
            text: $draft,
            isEditing: isEditing,
            pasteRequest: $pasteRequest,
            detectedLinks: detectedLinks
        ) { url in
            safariURL = SafariItem(url: url)
        }
    }

    // MARK: - Données

    private static func links(in content: String) async -> [DetectedTextLink] {
        await Task.detached(priority: .userInitiated) {
            guard let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
            ) else { return [] }

            let range = NSRange(location: 0, length: (content as NSString).length)
            return detector.matches(in: content, options: [], range: range).compactMap { match in
                guard let url = match.url else { return nil }
                return DetectedTextLink(range: match.range, url: url)
            }
        }.value
    }

    /// La vue texte et la détection des liens travaillent sur une chaîne
    /// complète en mémoire. Au-delà de cette limite, ouvrir le fichier ferait
    /// courir un risque de forte pression mémoire, notamment dans LiveContainer.
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
            let links = await Self.links(in: decoded)
            content = decoded
            draft = decoded
            detectedLinks = links
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
            let savedDraft = draft
            let data = Data(savedDraft.utf8)
            guard data.count <= Self.maximumEditableBytes else {
                throw TextFileViewerError.tooLarge(maximumBytes: Self.maximumEditableBytes)
            }
            try await service.uploadContent(driveId: driveId, fileId: file.id, data: data)
            await MediaURLCache.shared.invalidate(driveId: driveId, fileId: file.id)
            let links = await Self.links(in: savedDraft)
            content = savedDraft
            detectedLinks = links
            let allChangesSaved = draft == savedDraft
            if allChangesSaved {
                isEditing = false
            }
            return allChangesSaved
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

private struct TextPasteRequest {
    let id = UUID()
    let text: String
}

private struct DetectedTextLink: Sendable {
    let range: NSRange
    let url: URL
}

/// Une seule vue UIKit sert à la lecture et à la modification afin de garder
/// exactement le même défilement et la même sélection entre les deux modes.
private struct TextFileTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditing: Bool
    @Binding var pasteRequest: TextPasteRequest?
    let detectedLinks: [DetectedTextLink]
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        let baseFont = UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: baseFont)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = false
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.delegate = context.coordinator
        textView.text = text
        configureMode(textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        let modeChanged = textView.isEditable != isEditing
        let textChanged = textView.text != text
        let offset = textView.contentOffset
        let selection = textView.selectedRange

        if textChanged {
            textView.text = text
        }
        if modeChanged {
            configureMode(textView)
        }

        if textChanged || modeChanged {
            let textLength = (textView.text as NSString).length
            let location = min(selection.location, textLength)
            let length = min(selection.length, textLength - location)
            textView.selectedRange = NSRange(location: location, length: length)

            // Le changement de mode et la détection des liens peuvent lancer
            // une nouvelle mise en page ; restaurer après celle-ci évite tout
            // saut visible dans le document.
            DispatchQueue.main.async {
                textView.setContentOffset(offset, animated: false)
            }
        }

        if let pasteRequest,
           context.coordinator.lastPasteRequestID != pasteRequest.id {
            context.coordinator.lastPasteRequestID = pasteRequest.id
            DispatchQueue.main.async {
                context.coordinator.paste(pasteRequest, into: textView)
            }
        }
    }

    private func configureMode(_ textView: UITextView) {
        textView.isEditable = false
        textView.textContainerInset = UIEdgeInsets(
            top: 12,
            left: 12,
            bottom: isEditing ? 160 : 80,
            right: 12
        )

        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.textStorage.removeAttribute(.link, range: fullRange)
        if !isEditing {
            for link in detectedLinks where NSMaxRange(link.range) <= fullRange.length {
                textView.textStorage.addAttribute(.link, value: link.url, range: link.range)
            }
        }
        textView.isEditable = isEditing
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TextFileTextView
        var lastPasteRequestID: UUID?

        init(parent: TextFileTextView) {
            self.parent = parent
            lastPasteRequestID = parent.pasteRequest?.id
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func paste(_ request: TextPasteRequest, into textView: UITextView) {
            defer {
                if parent.pasteRequest?.id == request.id {
                    parent.pasteRequest = nil
                }
            }
            guard parent.isEditing,
                  textView.isEditable,
                  !request.text.isEmpty else { return }

            textView.insertText("\n\(request.text)\n")
            parent.text = textView.text
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case let .link(url) = textItem.content,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                return defaultAction
            }

            let onOpenURL = parent.onOpenURL
            return UIAction { _ in onOpenURL(url) }
        }
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
