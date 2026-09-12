import Foundation

/// Mutations : corbeille, restauration, renommage, couleur, déplacement.
extension KDriveService {
    /// Déplace un fichier ou dossier dans la corbeille.
    func trash(driveId: Int, fileId: Int) async throws {
        try await api.sendEmpty(.trash(driveId: driveId, fileId: fileId), method: "DELETE")
    }

    /// Supprime définitivement un fichier ou dossier de la corbeille.
    func permanentlyDelete(driveId: Int, fileId: Int) async throws {
        try await api.sendEmpty(.permanentDelete(driveId: driveId, fileId: fileId), method: "DELETE")
    }

    /// Restaure un fichier ou dossier depuis la corbeille.
    /// `destinationDirectoryId` : dossier de destination (dossier d'origine
    /// ou racine du drive).
    func restore(driveId: Int, fileId: Int, destinationDirectoryId: Int) async throws {
        let body = try JSONEncoder().encode(["destination_directory_id": destinationDirectoryId])
        try await api.post(.restore(driveId: driveId, fileId: fileId), body: body, contentType: "application/json")
    }

    /// Renomme un fichier ou dossier.
    func rename(driveId: Int, fileId: Int, name: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        try await api.post(.rename(driveId: driveId, fileId: fileId), body: body, contentType: "application/json")
    }

    /// Change la couleur d'un dossier (`#rrggbb`).
    func setFolderColor(driveId: Int, fileId: Int, color: String) async throws {
        let body = try JSONEncoder().encode(["color": color])
        try await api.post(.updateFolderColor(driveId: driveId, fileId: fileId), body: body, contentType: "application/json")
    }

    /// Déplace un fichier ou dossier vers `destinationDirectoryId`.
    func move(driveId: Int, fileId: Int, destinationDirectoryId: Int) async throws {
        try await api.sendEmpty(
            .move(driveId: driveId, fileId: fileId, destinationDirectoryId: destinationDirectoryId),
            method: "POST"
        )
    }
}
