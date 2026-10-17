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

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The details presentation did not settle")
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

    final class Frames {
        var title = CGRect.zero
        var header = CGRect.zero
        var cards = CGRect.zero
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

    func testCardTitleUsesNinetyFivePercentAndPadHeaderStaysAboveCards() async throws {
        let frames = Frames()
        let fixture = VStack {
            CardNameLayout {
                Text("Un nom de fichier très long qui doit remplir la largeur disponible")
                    .lineLimit(2).frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.title = $0 }
            }
            .frame(width: 240)
            ScrollView {
                Color.clear.frame(height: 1000)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.cards = $0 }
            }
            .modifier(FileBrowserHeader {
                Text("Tags / Dossier / Sous-dossier").frame(height: 44)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.header = $0 }
            })
        }
        .environment(\.iPadLayout, IPadLayout(isPad: true, width: 1000))
        let host = UIHostingController(rootView: fixture)
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
        try await waitUntil { frames.title.width > 0 && frames.header.height > 0 && frames.cards.height > 0 }
        XCTAssertEqual(frames.title.width, 228, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(frames.cards.minY, frames.header.maxY)
    }
}
