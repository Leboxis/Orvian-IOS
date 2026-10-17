import SwiftUI

/// Chaque onglet natif isole sa pile et ses commandes des autres onglets.
struct IPadTabView<Content: View>: View {
    @Binding private var selection: AppTab
    private let content: (AppTab) -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    init(selection: Binding<AppTab>, @ViewBuilder content: @escaping (AppTab) -> Content) {
        self._selection = selection
        self.content = content
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppTab.settings.title, systemImage: AppTab.settings.symbol, value: AppTab.settings) {
                content(.settings)
            }
            Tab(AppTab.tag.title, systemImage: AppTab.tag.symbol, value: AppTab.tag) {
                content(.tag)
            }
            Tab(AppTab.home.title, systemImage: AppTab.home.symbol, value: AppTab.home) {
                content(.home)
            }
            Tab(AppTab.favorites.title, systemImage: AppTab.favorites.symbol, value: AppTab.favorites) {
                content(.favorites)
            }
            Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                content(.profile)
            }
        }
        .tabViewStyle(.tabBarOnly)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.iPadLayout, IPadLayout(isPad: true, width: width, largeText: dynamicTypeSize.isAccessibilitySize))
    }
}
