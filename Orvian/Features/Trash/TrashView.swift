import SwiftUI

/// Corbeille du drive : consultation (miniatures et restauration),
/// sélection (un par un ou tout d'un coup) et suppression définitive.
struct TrashView: View {
    let driveId: Int
    let router: ViewerRouter

    @State private var viewModel: FileGridViewModel
    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showDeleteConfirm = false
    /// Fichier tapé hors mode sélection : restauration ou suppression définitive.
    @State private var tappedFile: DriveFile?
    @State private var showFileActions = false

    init(driveId: Int, router: ViewerRouter) {
        self.driveId = driveId
        self.router = router
        _viewModel = State(initialValue: FileGridViewModel(source: .trash, driveId: driveId))
    }

    var body: some View {
        FileGridView(
            viewModel: viewModel,
            grouping: nil,
            onOpenDirectory: { tap($0) },
            onOpenFile: { file, _ in tap(file) },
            searchText: "",
            filters: .init(),
            onScrolledPastTop: nil,
            allowsPullToRefresh: true,
            selectionMode: selectionMode,
            selectedIDs: selectedIDs,
            onToggleSelection: { file in toggle(file) }
        )
        .navigationTitle("Corbeille")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        endSelection()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("Annuler la sélection")
                }

                ToolbarItem(placement: .principal) {
                    Text(selectionTitle)
                        .font(.headline)
                        .lineLimit(1)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        toggleAll()
                    } label: {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityLabel(allSelected ? "Tout désélectionner" : "Tout sélectionner")

                    Button {
                        Task { await restoreSelected() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityLabel("Restaurer")

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityLabel("Supprimer définitivement")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectionMode = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .disabled(viewModel.items.isEmpty)
                    .accessibilityLabel("Sélectionner")
                }
            }
        }
        .confirmationDialog("Supprimer définitivement ?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Supprimer \(selectedIDs.count) élément\(selectedIDs.count > 1 ? "s" : "")", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est irréversible : les fichiers sélectionnés seront définitivement effacés du drive.")
        }
        .confirmationDialog(
            "« \(tappedFile?.name ?? "") » est dans la corbeille",
            isPresented: $showFileActions,
            titleVisibility: .visible
        ) {
            if let file = tappedFile {
                Button(file.isImage || file.isVideo ? "Restaurer et ouvrir" : "Restaurer") {
                    Task { await restoreAndOpen(file) }
                }
                Button("Supprimer définitivement", role: .destructive) {
                    Task { await viewModel.permanentlyDelete(file) }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La restauration remet le fichier à son emplacement d'origine (ou à la racine du drive).")
        }
    }

    /// Tous les éléments actuellement chargés sont-ils sélectionnés ?
    private var allSelected: Bool {
        !viewModel.items.isEmpty && selectedIDs.isSuperset(of: Set(viewModel.items.map(\.id)))
    }

    private var selectionTitle: String {
        guard !selectedIDs.isEmpty else { return "Sélection" }
        return "\(selectedIDs.count) sélectionné\(selectedIDs.count > 1 ? "s" : "")"
    }

    private func startSelection() {
        selectionMode = true
    }

    private func endSelection() {
        selectionMode = false
        selectedIDs.removeAll()
    }

    private func toggle(_ file: DriveFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    private func toggleAll() {
        if allSelected {
            selectedIDs = []
        } else {
            selectedIDs = Set(viewModel.items.map(\.id))
        }
    }

    private func tap(_ file: DriveFile) {
        tappedFile = file
        showFileActions = true
    }

    /// Restaure le fichier puis l'ouvre dans la visionneuse si c'est une
    /// image ou une vidéo (seul moyen de les consulter depuis la corbeille).
    private func restoreAndOpen(_ file: DriveFile) async {
        let restored = await viewModel.restore(file)
        if restored, file.isImage || file.isVideo {
            router.open(file, siblings: [file])
        }
    }

    private func restoreSelected() async {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let restored = await viewModel.restore(ids: ids)
        selectedIDs.subtract(restored)
        if selectedIDs.isEmpty {
            selectionMode = false
        }
    }

    private func deleteSelected() async {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let deleted = await viewModel.permanentlyDelete(ids: ids)
        // Ne retire de la sélection que les suppressions réussies : en cas
        // d'échec total ou partiel, l'utilisateur garde le reste sélectionné
        // pour retenter sans tout recommencer (l'erreur est affichée par
        // l'alerte de FileGridView).
        selectedIDs.subtract(deleted)
        if selectedIDs.isEmpty {
            selectionMode = false
        }
    }
}