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
            // The breadcrumb/search row owns layout space instead of covering
            // the scroll view's top edge with an opaque safe-area overlay.
            VStack(spacing: 0) {
                if isVisible {
                    VStack(spacing: 8) {
                        if searchPresented {
                            search().transition(.opacity)
                        }
                        summary
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .background {
                // Every pushed browser paints the same surface beneath the native bar.
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
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
