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
    /// Incrémenté à chaque modification de la requête ou du document : rend
    /// obsolète tout balayage lancé avant la dernière frappe.
    @State private var searchGeneration = 0
    @State private var searchTask: Task<Void, Never>?
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
            scheduleSearchUpdate()
        }
        .onChange(of: draft) { _, _ in
            if isSearching {
                scheduleSearchUpdate()
            }
        }
        .onChange(of: isSearching) { _, newValue in
            scheduleSearchUpdate()
            if newValue {
                isSearchFieldFocused = true
            }
        }
        .onDisappear {
            cancelSearch()
        }
        .onAppear {
            if isSearching { scheduleSearchUpdate() }
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

    /// Planifie un balayage de recherche : décalé de 200 ms pour ne pas lancer
    /// un balayage par frappe, puis exécuté hors du MainActor. Toute frappe
    /// ultérieure invalide le résultat via `searchGeneration`.
    private func scheduleSearchUpdate() {
        cancelSearch()
        let query = searchQuery
        guard isSearching, !query.isEmpty else {
            searchRanges = []
            currentSearchIndex = nil
            return
        }
        let generation = searchGeneration
        let document = draft
        searchTask = Task { @MainActor [self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch { return }
            guard !Task.isCancelled, generation == searchGeneration else { return }
            let ranges = await TextSearch.ranges(query: query, in: document)
            guard !Task.isCancelled, generation == searchGeneration,
                  isSearching, searchQuery == query, draft == document else { return }
            applySearch(ranges: ranges)
            searchTask = nil
        }
    }

    /// Invalide aussi les résultats déjà calculés mais pas encore affichés.
    private func cancelSearch() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
    }

    /// Applique le résultat du balayage : même règle de conservation de la
    /// position courante que l'ancien balayage synchrone.
    private func applySearch(ranges: [NSRange]) {
        let previousIndex = currentSearchIndex
        let previousCount = searchRanges.count
        searchRanges = ranges
        if ranges.isEmpty {
            currentSearchIndex = nil
        } else if let index = previousIndex, index < ranges.count,
                  previousCount == ranges.count || draft.isEmpty {
            // Conserve la position si possible.
            currentSearchIndex = index
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
            let data = try await BoundedDataLoader.load(from: url, maximumBytes: Self.maximumEditableBytes)
            let decoded = try await Task.detached(priority: .userInitiated) {
                try TextFileContent.decode(data)
            }.value
            try Task.checkCancellation()
            let links = await Self.links(in: decoded)
            content = decoded
            draft = decoded
            detectedLinks = links
            if isSearching {
                scheduleSearchUpdate()
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
        applySearchHighlights(to: textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        let modeChanged = textView.isEditable != isEditing
        let textChanged = textView.text != text
        let offset = textView.contentOffset
        let selection = textView.selectedRange

        if textChanged {
            // `textView.text = ...` réinitialise tous les attributs (liens et
            // surlignages) : la prochaine passe doit donc tout redessiner.
            context.coordinator.highlightedCount = 0
            textView.text = text
        }
        // `textView.text = ...` rase les attributs `.link` : reposer les liens
        // après chaque changement de texte, pas seulement au changement de mode.
        if modeChanged || textChanged {
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

        // Réapplique les surlignages de recherche après les liens, mais
        // uniquement s'il y a quelque chose à dessiner **ou** à nettoyer :
        // auparavant, le retrait des attributs balayait l'intégralité du
        // document à chaque mise à jour SwiftUI, même sans recherche active.
        applySearchHighlights(to: textView, coordinator: context.coordinator)
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

    private func applySearchHighlights(to textView: UITextView, coordinator: Coordinator) {
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        guard fullRange.length > 0 else { return }
        // Rien à dessiner et rien à nettoyer : ne pas reparcourir le document.
        guard !searchRanges.isEmpty || coordinator.highlightedCount > 0 else { return }
        // Nettoie les anciens surlignages.
        textView.textStorage.removeAttribute(.backgroundColor, range: fullRange)

        var drawn = 0
        for (index, range) in searchRanges.enumerated() where range.location != NSNotFound && NSMaxRange(range) <= fullRange.length {
            let isCurrent = index == currentSearchIndex
            let color: UIColor = isCurrent
                ? UIColor.systemOrange.withAlphaComponent(0.45)
                : UIColor.systemYellow.withAlphaComponent(0.45)
            textView.textStorage.addAttribute(.backgroundColor, value: color, range: range)
            drawn += 1
        }
        coordinator.highlightedCount = drawn
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
        /// Nombre de surlignages posés lors de la dernière passe : il décide
        /// si le retrait des attributs doit balayer à nouveau le document.
        var highlightedCount = 0

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
