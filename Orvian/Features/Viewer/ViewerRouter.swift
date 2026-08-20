import Foundation
import Observation

/// Contexte de la visionneuse photos (pager sur les images voisines).
struct PhotoViewerContext: Identifiable {
    let driveId: Int
    let files: [DriveFile]
    let startIndex: Int

    var id: String { "\(driveId)-\(files.map(\.id).hashValue)-\(startIndex)" }
}

/// Ouvre les visionneuses plein écran depuis n'importe quelle grille.
@MainActor
@Observable
final class ViewerRouter {
    var photoContext: PhotoViewerContext?
    var videoFile: DriveFile?
    var textFile: DriveFile?

    let driveId: Int

    init(driveId: Int) {
        self.driveId = driveId
    }

    func open(_ file: DriveFile, siblings: [DriveFile]) {
        MediaUsageStore.recordView(driveId: driveId, file: file)
        if file.isVideo {
            videoFile = file
        } else if file.isImage {
            let images = siblings.filter { $0.isImage }
            let index = images.firstIndex(where: { $0.id == file.id }) ?? 0
            photoContext = PhotoViewerContext(driveId: driveId, files: images, startIndex: index)
        } else if file.isPlainText {
            textFile = file
        }
    }
}
