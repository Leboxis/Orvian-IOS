import SwiftUI

/// Corbeille du drive : consultation, sélection (un par un ou tout d'un
/// coup) et suppression définitive.
struct TrashView: View {
    let driveId: Int

    @State private var viewModel: FileGridViewModel
    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showDeleteConfirm = false

    init(driveId: Int) {
        self.driveId = driveId
        _viewModel = State(initialValue: FileGridViewModel(source: .trash, driveId: driveId))
    }

    var body: some View {
        FileGridView(
            viewModel: viewModel,
            grouping: nil,
            onOpenDirectory: nil,
            onOpenFile: nil,
            onInitialLoad: nil,
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
                    Button("Annuler") {
                        selectionMode = false
                        selectedIDs = []
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Tout désélectionner" : "Tout sélectionner") {
                        toggleAll()
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectionMode = true
                    } label: {
                        Label("Sélectionner", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode && !selectedIDs.isEmpty {
                deleteBar
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
    }

    /// Tous les éléments actuellement chargés sont-ils sélectionnés ?
    private var allSelected: Bool {
        !viewModel.items.isEmpty && selectedIDs.isSuperset(of: Set(viewModel.items.map(\.id)))
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

    /// Barre d'action collée en bas quand une sélection existe.
    private var deleteBar: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Supprimer définitivement", systemImage: "trash.slash")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func deleteSelected() async {
        await viewModel.permanentlyDelete(ids: selectedIDs)
        selectedIDs = []
        selectionMode = false
    }
}