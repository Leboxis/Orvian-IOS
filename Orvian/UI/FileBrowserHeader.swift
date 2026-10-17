import SwiftUI

/// iPad browser summaries occupy their own row, outside the scrolling cards.
/// A safe-area overlay lets the first row scroll behind transparent breadcrumbs.
struct FileBrowserHeader<Header: View>: ViewModifier {
    @Environment(\.iPadLayout) private var layout
    @ViewBuilder var header: () -> Header

    func body(content: Content) -> some View {
        if layout.isPad {
            VStack(spacing: 0) {
                header()
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0, content: header)
        }
    }
}
