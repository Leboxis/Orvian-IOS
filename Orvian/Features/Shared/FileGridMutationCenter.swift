import Combine
import Foundation

/// Diffuse les mutations deja confirmees par l'API aux grilles encore visibles.
enum FileGridMutation {
    case favorite(driveId: Int, fileId: Int, isFavorite: Bool)
    case category(driveId: Int, fileId: Int, category: Category, applied: Bool)

    var driveId: Int {
        switch self {
        case let .favorite(driveId, _, _), let .category(driveId, _, _, _):
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
