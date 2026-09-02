import Combine
import Foundation

/// Diffuse les mutations deja confirmees par l'API aux grilles encore visibles.
enum FileGridMutation {
    case favorite(driveId: Int, fileId: Int, isFavorite: Bool)
    case category(driveId: Int, fileId: Int, category: Category, applied: Bool)
    /// Éléments confirmés retirés d'une liste (corbeille ou déplacement) :
    /// les grilles concernées retirent les cartes immédiatement, sans
    /// rechargement réseau.
    case removal(driveId: Int, fileIds: Set<Int>)

    var driveId: Int {
        switch self {
        case let .favorite(driveId, _, _), let .category(driveId, _, _, _), let .removal(driveId, _):
            return driveId
        }
    }
}

final class FileGridMutationCenter {
    static let shared = FileGridMutationCenter()

    let mutations = PassthroughSubject<FileGridMutation, Never>()

    private init() {}

    func publish(_ mutation: FileGridMutation) {
        mutations.send(mutation)
    }
}
