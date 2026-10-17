import SwiftUI

struct FilePresentationToggle: View {
    @Environment(\.fileBrowserScope) private var scope
    @AppStorage("homeFilePresentation") private var home = FilePresentation.grid
    @AppStorage("favoritesFilePresentation") private var favorites = FilePresentation.grid
    @AppStorage("tagFilePresentation") private var tags = FilePresentation.grid
    private var selection: FilePresentation {
        switch scope { case .home: return home; case .favorites: return favorites; case .tag: return tags }
    }
    var body: some View {
        Button {
            let next: FilePresentation = selection == .grid ? .list : .grid
            switch scope { case .home: home = next; case .favorites: favorites = next; case .tag: tags = next }
        } label: {
            Label(selection == .grid ? "Afficher en liste" : "Afficher en grille",
                  systemImage: selection == .grid ? "list.bullet" : "square.grid.2x2")
        }
        .accessibilityIdentifier("browser.presentation")
    }
}
