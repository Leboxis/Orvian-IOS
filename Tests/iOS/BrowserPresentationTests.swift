import SwiftUI
import XCTest
@testable import Orvian

/// Native presentation/layout assertions only; no images or screenshots.
@MainActor
final class BrowserPresentationTests: XCTestCase {
    private enum WaitError: Error { case timeout }
    @Observable final class Selection {
        var file: DriveFile?
    }

    struct DetailFixture: View {
        let selection: Selection
        let inspector: Bool
        let split: Bool

        private var browser: some View {
            @Bindable var selection = selection
            return Text("Browser")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(FileDetailsPresentation(file: $selection.file,
                    usesInspector: inspector, driveId: 42, isTrashed: true))
        }

        var body: some View {
            if split {
                NavigationSplitView { Text("Tags") } detail: {
                    NavigationStack { browser }
                }
            } else {
                NavigationStack { browser }
            }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitUntil(message: @autoclosure () -> String = "The native presentation did not settle",
                           _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message())
        throw WaitError.timeout
    }

    func testDetailsOpenReplaceAndCloseInStackAndTagSplit() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        // iPhone/narrow iPad sheet, wide iPad inspector, Tags split inspector.
        let modes: [(Bool, Bool)] = UIDevice.current.userInterfaceIdiom == .pad
            ? [(false, false), (true, false), (true, true)] : [(false, false)]
        for (inspector, split) in modes {
            let selection = Selection()
            let host = UIHostingController(rootView: AnyView(DetailFixture(selection: selection, inspector: inspector, split: split)))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(150))
            func scrollCount() -> Int {
                descendants(window).filter { $0 is UIScrollView }.count
            }
            let baseline = scrollCount()
            for _ in 0..<3 {
                selection.file = .root(name: "Premier dossier")
                try await waitUntil { scrollCount() > baseline }
                selection.file = .root(name: "Autre nom, même élément")
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNotNil(selection.file)
                selection.file = nil
                try await waitUntil { scrollCount() == baseline }
            }
            // Unmount navigation while its window is still visible. UIKit
            // must finish retiring the inspector before another host takes over.
            host.rootView = AnyView(EmptyView())
            try await waitUntil { scrollCount() == 0 && host.presentedViewController == nil }
        }
    }

    /// Keep weak probes, not frame snapshots: UIKit may reposition a toolbar's
    /// hosting root without laying out its unchanged 44-point child again.
    struct WindowFrameProbe: UIViewRepresentable {
        let onView: (UIView) -> Void

        func makeUIView(context: Context) -> UIView { UIView() }
        func updateUIView(_ view: UIView, context: Context) { onView(view) }
    }

    final class Frames {
        weak var titleView: UIView?
        weak var headerView: UIView?
        weak var cardsView: UIView?
        weak var commandView: UIView?

        private func frame(of view: UIView?) -> CGRect {
            guard let view, let window = view.window else { return .zero }
            return view.convert(view.bounds, to: window)
        }

        var title: CGRect { frame(of: titleView) }
        var header: CGRect { frame(of: headerView) }
        var cards: CGRect { frame(of: cardsView) }
        var command: CGRect { frame(of: commandView) }
        var sample: [CGRect] { [title, header, cards, command] }

        func areAttached(to window: UIWindow) -> Bool {
            [titleView, headerView, cardsView, commandView].allSatisfy { $0?.window === window }
        }
    }

    func testWindowFrameProbeFollowsAncestorMovementWithoutChildRelayout() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let toolbarRoot = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 44))
        let probe = UIView(frame: CGRect(x: 300, y: 0, width: 44, height: 44))
        window.addSubview(toolbarRoot)
        toolbarRoot.addSubview(probe)
        let frames = Frames()
        frames.commandView = probe
        let initial = frames.command

        // A native tab bar can move the hosting root without changing the
        // probe's local bounds or asking it to lay out again.
        toolbarRoot.frame.origin.y += 54
        XCTAssertEqual(probe.bounds.size, initial.size)
        XCTAssertEqual(frames.command.midY, initial.midY + 54, accuracy: 0.01)
        XCTAssertEqual(frames.command.size, initial.size)
    }

    func testActualGridDetailsActionInEachBrowserScope() async throws {
        // Seed a fresh in-memory listing, then remove the dummy credential
        // before mounting any view. No network or real account is involved.
        guard TokenStore.current() == nil else {
            XCTFail("Use a clean test simulator without account credentials")
            return
        }
        TokenStore.save("details-test-" + UUID().uuidString)
        let source = FileSource.trash
        DirectoryListStore.shared.store(source: source, driveId: -9001, orderBy: [], order: "asc",
            items: [.root(name: "Dossier de test")], cursor: nil, hasMore: false, totalItemCount: 1)
        let model = FileGridViewModel(source: source, driveId: -9001)
        await model.loadIfNeeded()
        TokenStore.clear()
        XCTAssertEqual(model.items.count, 1)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for scope in [FileBrowserScope.home, .favorites, .tag] {
            let browser = NavigationStack {
                FileGridView(viewModel: model, onOpenDirectory: { _ in })
                    .environment(\.fileBrowserScope, scope)
                    .environment(\.iPadLayout, IPadLayout(isPad: UIDevice.current.userInterfaceIdiom == .pad, width: 1366))
            }
            let host = UIHostingController(rootView: AnyView(browser))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await waitUntil {
                self.descendants(window).contains { $0.accessibilityLabel == "Dossier de test" }
            }
            let card = try XCTUnwrap(descendants(window).compactMap { $0 as? UIButton }
                .first { $0.accessibilityLabel == "Dossier de test" })
            let baseline = descendants(window).filter { $0 is UIScrollView }.count
            let details = try XCTUnwrap(card.accessibilityCustomActions?.first { $0.name == "Détails" })
            XCTAssertEqual(details.actionHandler?(details), true)
            try await waitUntil {
                self.descendants(window).filter { $0 is UIScrollView }.count > baseline
            }
            if host.presentedViewController != nil {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    host.dismiss(animated: false) { continuation.resume() }
                }
            }
            host.rootView = AnyView(EmptyView())
            try await waitUntil {
                self.descendants(window).allSatisfy { !($0 is UIScrollView) }
                    && host.presentedViewController == nil
            }
            window.isHidden = true
            window.rootViewController = nil
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    func testCardTitleUsesNinetyFivePercentAndPadSummarySharesTopToolbar() async throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad,
                      "Native iPad toolbar geometry is exercised on the dedicated iPad destination.")
        let frames = Frames()
        // Native tabs may lay out inactive panes too. Only the selected pane
        // may publish into these shared probes; hidden toolbar frames are not
        // coordinates of the visible Home toolbar.
        let fixture = IPadTabView(selection: .constant(.home)) { tab in
            NavigationStack {
                VStack {
                    CardNameLayout {
                        Text("Un nom de fichier très long qui doit remplir la largeur disponible")
                            .lineLimit(1).frame(maxWidth: .infinity)
                            .background(WindowFrameProbe { view in
                                if tab == .home { frames.titleView = view }
                            })
                    }
                    .frame(width: 240)
                    ScrollView {
                        Color.clear.frame(height: 1000)
                            .background(WindowFrameProbe { view in
                                if tab == .home { frames.cardsView = view }
                            })
                    }
                }
                .modifier(FileBrowserHeader {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tags / Dossier / Sous-dossier").lineLimit(1)
                        Text("12 éléments")
                    }
                    .font(.caption).frame(width: 180)
                    .background(WindowFrameProbe { view in
                        if tab == .home { frames.headerView = view }
                    })
                })
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {} label: {
                            Image(systemName: "checkmark.circle")
                                .frame(width: 44, height: 44)
                                .background(WindowFrameProbe { view in
                                    if tab == .home { frames.commandView = view }
                                })
                        }
                        .accessibilityLabel("Sélectionner")
                        .accessibilityIdentifier("fixture.select")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .environment(\.iPadLayout, IPadLayout(isPad: true, width: 1000))
        let host = UIHostingController(rootView: AnyView(fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        host.view.layoutIfNeeded()
        var failure: Error?
        var previousSample: [CGRect]?
        do {
            try await waitUntil(message: "Toolbar probes did not settle: title=\(frames.title), header=\(frames.header), cards=\(frames.cards), command=\(frames.command)") {
                window.layoutIfNeeded()
                let sample = frames.sample
                defer { previousSample = sample }
                return frames.areAttached(to: window) && sample.allSatisfy { !$0.isEmpty }
                    && sample == previousSample
            }
            let diagnostics = "Toolbar probe frames: title=\(frames.title), header=\(frames.header), cards=\(frames.cards), command=\(frames.command)"
            XCTAssertEqual(frames.title.width, 228, accuracy: 0.5, diagnostics)
            let command = frames.command
            XCTAssertEqual(frames.header.midY, command.midY, accuracy: 2,
                           "The summary must share the system toolbar's vertical center, not add a content row. \(diagnostics)")
            XCTAssertGreaterThanOrEqual(frames.cards.minY, frames.header.maxY, diagnostics)
        } catch {
            failure = error
        }
        // Retire native tab/navigation controllers before destroying their window,
        // including timeout paths; otherwise UIKit can throw failed(deinit).
        host.rootView = AnyView(EmptyView())
        try await waitUntil {
            !self.descendants(window).contains { $0 is UINavigationBar }
                && host.presentedViewController == nil
        }
        if let failure { throw failure }
    }
}
