import SwiftUI

/// iPad summaries share the top system bar with the native tabs and commands.
/// iPhone summaries occupy the safe area above the scrolling cards.
struct FileBrowserHeader<Header: View>: ViewModifier {
    @Environment(\.iPadLayout) private var layout
    @ViewBuilder var header: () -> Header

    func body(content: Content) -> some View {
        if layout.isPad {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    header()
                        .accessibilityIdentifier("browser.summary")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0, content: header)
        }
    }
}
