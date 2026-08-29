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
/// l'édition. Sert aussi de repli pour les fichiers sans extension visible :
/// un contenu binaire y est détecté et refusé proprement.
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

    // MARK: - Recherche

    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var searchRanges: [NSRange] = []
    @State private var currentSearchIndex: Int?
    @FocusState private var isSearchFieldFocused: Bool

    private let service = KDriveService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isSearching {
                    searchBar
                }
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
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isLoading && loadError == nil {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                isSearching.toggle()
                            }
                            if isSearching {
                                // Le focus doit être posé après l'animation d'apparition.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    isSearchFieldFocused = true
                                }
                            } else {
                                searchQuery = ""
                            }
                        } label: {
                            Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        }
                        .accessibilityLabel(isSearching ? "Fermer la recherche" : "Rechercher dans le document")

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
        .onChange(of: searchQuery) { _, _ in
            updateSearchResults()
        }
        .onChange(of: draft) { _, _ in
            if isSearching {
                updateSearchResults()
            }
        }
        .onChange(of: isSearching) { _, newValue in
            if newValue {
                updateSearchResults()
                isSearchFieldFocused = true
            } else {
                searchRanges = []
                currentSearchIndex = nil
            }
        }
    }

    // MARK: - Barre de recherche

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
                TextField("Rechercher", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($isSearchFieldFocused)
                    .onSubmit { goToNext() }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    }
                    .accessibilityLabel("Effacer la recherche")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if !searchQuery.isEmpty {
                Text(searchResultLabel)
                    .font(.caption)
                    .foregroundStyle(searchRanges.isEmpty ? .red : .secondary)
                    .monospacedDigit()
                    .frame(minWidth: 56)
                    .lineLimit(1)

                Button {
                    goToPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(searchRanges.isEmpty)
                .accessibilityLabel("Occurrence précédente")

                Button {
                    goToNext()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(searchRanges.isEmpty)
                .accessibilityLabel("Occurrence suivante")
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isSearching = false
                    searchQuery = ""
                }
            } label: {
                Text("Fermer")
                    .font(.subheadline)
            }
            .accessibilityLabel("Fermer la recherche")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var searchResultLabel: String {
        if searchQuery.isEmpty { return "" }
        if searchRanges.isEmpty { return "0 / 0" }
        guard let idx = currentSearchIndex else { return "\(searchRanges.count) résultats" }
        return "\(idx + 1) / \(searchRanges.count)"
    }

    private func updateSearchResults() {
        let query = searchQuery
        guard !query.isEmpty else {
            searchRanges = []
            currentSearchIndex = nil
            return
        }
        let previousIndex = currentSearchIndex
        let previousCount = searchRanges.count
        let nsDraft = draft as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsDraft.length)
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // Limite pour éviter de figer l'UI sur un document de 5 Mo avec une
        // requête très courte (ex. "e" → dizaines de milliers d'occurrences).
        let maxMatches = 2000
        while searchRange.location < nsDraft.length {
            let found = nsDraft.range(of: query, options: options, range: searchRange)
            if found.location == NSNotFound { break }
            ranges.append(found)
            if ranges.count >= maxMatches { break }
            let nextLocation = found.location + max(found.length, 1)
            if nextLocation >= nsDraft.length { break }
            searchRange = NSRange(location: nextLocation, length: nsDraft.length - nextLocation)
        }
        searchRanges = ranges
        if ranges.isEmpty {
            currentSearchIndex = nil
        } else if let idx = previousIndex, idx < ranges.count, previousCount == ranges.count || draft.count == 0 {
            // Conserve la position si possible.
            currentSearchIndex = idx
        } else {
            currentSearchIndex = 0
        }
    }

    private func goToNext() {
        guard !searchRanges.isEmpty else { return }
        if let idx = currentSearchIndex {
            currentSearchIndex = (idx + 1) % searchRanges.count
        } else {
            currentSearchIndex = 0
        }
    }

    private func goToPrevious() {
        guard !searchRanges.isEmpty else { return }
        if let idx = currentSearchIndex {
            currentSearchIndex = (idx - 1 + searchRanges.count) % searchRanges.count
        } else {
            currentSearchIndex = searchRanges.count - 1
        }
    }

    // MARK: - Lecture et modification

    private var textSurface: some View {
        TextFileTextView(
            text: $draft,
            isEditing: isEditing,
            pasteRequest: $pasteRequest,
            detectedLinks: detectedLinks,
            searchRanges: searchRanges,
            currentSearchIndex: currentSearchIndex,
            onOpenURL: { url in
                safariURL = SafariItem(url: url)
            }
        )
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
            guard !Self.isBinary(data) else {
                throw TextFileViewerError.binaryContent
            }
            let links = await Self.links(in: decoded)
            content = decoded
            draft = decoded
            detectedLinks = links
            if isSearching {
                updateSearchResults()
            }
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

    /// Détecte un contenu binaire (zip, image, PDF…) : la visionneuse est
    /// aussi proposée en repli pour les fichiers sans extension visible, il
    /// faut donc refuser proprement ce qui n'est pas du texte. Échantillon du
    /// début du fichier : un octet nul ou > 5 % d'octets de contrôle (hors
    /// tabulation, saut de ligne…) signent un binaire.
    private static func isBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        guard !sample.isEmpty else { return false }
        var controlBytes = 0
        for byte in sample {
            if byte == 0x00 { return true }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) {
                controlBytes += 1
            }
        }
        return Double(controlBytes) / Double(sample.count) > 0.05
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
    let searchRanges: [NSRange]
    let currentSearchIndex: Int?
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
        applySearchHighlights(to: textView)
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

        // Toujours réappliquer les surlignages de recherche (liens + occurrences).
        // `configureMode` a déjà nettoyé/posé les liens ; on ajoute ensuite les fonds.
        if !textChanged || textView.textStorage.length == (text as NSString).length {
            // Si le texte vient de changer, `configureMode` a été appelé, on
            // doit quand même poser les highlights après.
        }
        applySearchHighlights(to: textView)
        scrollToCurrentSearch(in: textView)

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

    private func applySearchHighlights(to textView: UITextView) {
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        guard fullRange.length > 0 else { return }
        // Nettoie les anciens surlignages.
        textView.textStorage.removeAttribute(.backgroundColor, range: fullRange)

        guard !searchRanges.isEmpty else { return }

        for (index, range) in searchRanges.enumerated() where range.location != NSNotFound && NSMaxRange(range) <= fullRange.length {
            let isCurrent = index == currentSearchIndex
            let color: UIColor = isCurrent
                ? UIColor.systemOrange.withAlphaComponent(0.45)
                : UIColor.systemYellow.withAlphaComponent(0.45)
            textView.textStorage.addAttribute(.backgroundColor, value: color, range: range)
        }
    }

    private func scrollToCurrentSearch(in textView: UITextView) {
        guard let idx = currentSearchIndex,
              idx >= 0, idx < searchRanges.count else { return }
        let range = searchRanges[idx]
        guard range.location != NSNotFound,
              NSMaxRange(range) <= textView.textStorage.length else { return }

        // Sélection visuelle de l'occurrence courante (sans déclencher
        // `textViewDidChange`). Utile en lecture pour bien voir la position.
        // En édition on ne force pas la sélection pour ne pas déplacer le curseur
        // de l'utilisateur s'il tape.
        if !isEditing {
            textView.selectedRange = range
        }
        // Le scroll doit intervenir après la mise en page.
        DispatchQueue.main.async {
            textView.scrollRangeToVisible(range)
        }
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
    case binaryContent

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
        case .binaryContent:
            return "Ce fichier n’est pas un document texte."
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
