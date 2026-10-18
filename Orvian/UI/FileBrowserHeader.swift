import SwiftUI

/// Search takes the centered toolbar slot on iPad and pushes the summary into
/// a reserved row. On iPhone both rows live above the scrolling cards.
struct FileBrowserHeader<Header: View, Search: View>: ViewModifier {
    @Environment(\.iPadLayout) private var layout
    var isVisible = true
    var searchPresented = false
    @ViewBuilder var search: () -> Search
    @ViewBuilder var header: () -> Header

    func body(content: Content) -> some View {
        if layout.isPad {
            content
            .safeAreaInset(edge: .top, spacing: 0) {
                if searchPresented {
                    summary.padding(.vertical, 4)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                if isVisible {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            if searchPresented {
                                search()
                                    .transition(.offset(y: -80).combined(with: .opacity))
                            } else {
                                summary.transition(.opacity)
                            }
                        }
                        .frame(maxWidth: 600)
                        .animation(Motion.animation(.snappy(duration: 0.3)), value: searchPresented)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .animation(Motion.animation(.snappy(duration: 0.3)), value: searchPresented)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    if searchPresented {
                        search().transition(.offset(y: -80).combined(with: .opacity))
                    }
                    summary
                }
                .padding(.vertical, isVisible ? 4 : 0)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .animation(Motion.animation(.snappy(duration: 0.3)), value: searchPresented)
        }
    }

    private var summary: some View {
        header()
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("browser.summary")
    }
}

extension FileBrowserHeader where Search == EmptyView {
    init(@ViewBuilder header: @escaping () -> Header) {
        self.init(isVisible: true, searchPresented: false, search: { EmptyView() }, header: header)
    }
}
