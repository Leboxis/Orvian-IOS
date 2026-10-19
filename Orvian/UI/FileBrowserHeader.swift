import SwiftUI

extension EnvironmentValues {
    @Entry var phoneBrowserHeaderHeight: CGFloat = 0
    @Entry var phoneBrowserBottomInset: CGFloat = 0
}

/// Search takes the centered toolbar slot on iPad. On iPhone the compact
/// header floats above the cards without cutting off their scrolling viewport.
struct FileBrowserHeader<Header: View, Search: View>: ViewModifier {
    @Environment(\.iPadLayout) private var layout
    @State private var phoneHeaderHeight: CGFloat = 0
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
            GeometryReader { geometry in
                content
                    .environment(\.phoneBrowserHeaderHeight, isVisible ? phoneHeaderHeight : 0)
                    // The expanded scroll viewport must retain clearance at its content's end.
                    .environment(\.phoneBrowserBottomInset, geometry.safeAreaInsets.bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .overlay(alignment: .top) {
                if isVisible {
                    VStack(spacing: 8) {
                        if searchPresented {
                            search().transition(.opacity)
                        }
                        header()
                            // Keep root summaries and ancestor menus the same height.
                            .frame(minHeight: 44)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityIdentifier("browser.summary")
                    }
                    .frame(maxWidth: 600)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        phoneHeaderHeight = $0
                    }
                }
            }
            .background {
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
