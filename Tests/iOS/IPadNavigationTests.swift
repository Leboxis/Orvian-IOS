import XCTest
import SwiftUI
@testable import Orvian

/// Conteneur réel, écrans locaux : aucun token ni appel réseau.
@MainActor
final class IPadNavigationTests: XCTestCase {
    private enum WaitError: Error { case timeout }
    final class Probe {
        var visibleTabs: Set<AppTab> = []
        var identities: [AppTab: UUID] = [:]
        var directories: [AppTab: String] = [:]
    }

    struct Pane: View {
        let tab: AppTab
        let probe: Probe
        @Binding var path: [DriveFile]
        @State private var identity = UUID()

        var body: some View {
            NavigationStack(path: $path) {
                Text(tab.title)
                    .navigationTitle(tab.title)
                    .onAppear { probe.directories[tab] = tab.title }
                    .toolbar {
                        Button("Filtrer") {}
                    }
                    .navigationDestination(for: DriveFile.self) { folder in
                        Text(folder.name)
                            .navigationTitle(folder.name)
                            .onAppear { probe.directories[tab] = folder.name }
                    }
            }
            .onAppear {
                probe.visibleTabs.insert(tab)
                probe.identities[tab] = identity
            }
            .onDisappear {
                probe.visibleTabs.remove(tab)
                probe.directories[tab] = nil
            }
        }
    }

    struct Fixture: View {
        let shell: MainTabShellState
        let probe: Probe

        var body: some View {
            @Bindable var shell = shell
            IPadTabView(selection: $shell.tab) { tab in
                switch tab {
                case .home:
                    Pane(tab: tab, probe: probe, path: $shell.navState.homePath)
                case .favorites:
                    Pane(tab: tab, probe: probe, path: $shell.navState.favoritesPath)
                default:
                    Pane(tab: tab, probe: probe, path: .constant([]))
                }
            }
        }
    }

    private func folder(_ id: Int, name: String) throws -> DriveFile {
        let object: [String: Any] = ["id": id, "name": name, "type": "dir"]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The native tab did not settle into the expected navigation state")
        throw WaitError.timeout
    }

    func testNativeTabsKeepIndependentFoldersAcrossTenCycles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let shell = MainTabShellState(driveId: 42)
        let probe = Probe()
        window.rootViewController = UIHostingController(rootView: Fixture(shell: shell, probe: probe))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await waitUntil { probe.visibleTabs == Set([.home]) }

        let home = try [folder(101, name: "Images"), folder(102, name: "À classer")]
        let favorites = try [folder(201, name: "Dossier favori")]
        shell.navState.homePath = home
        try await waitUntil { probe.directories[.home] == "À classer" }
        shell.navState.favoritesPath = favorites

        var identities: [AppTab: UUID] = [:]
        for _ in 0..<10 {
            for tab in [AppTab.home, .favorites, .tag, .profile, .settings] {
                shell.tab = tab
                try await waitUntil { probe.visibleTabs == Set([tab]) }
                if let identity = identities[tab] {
                    XCTAssertEqual(probe.identities[tab], identity, "Revisiting a tab must not replace its local state")
                } else {
                    identities[tab] = try XCTUnwrap(probe.identities[tab])
                }
                XCTAssertEqual(shell.navState.homePath, home)
                XCTAssertEqual(shell.navState.favoritesPath, favorites)
                if tab == .home {
                    try await waitUntil { probe.directories[.home] == "À classer" }
                } else if tab == .favorites {
                    try await waitUntil { probe.directories[.favorites] == "Dossier favori" }
                }
            }
        }
        XCTAssertEqual(identities.count, AppTab.allCases.count)
    }

    func testResettingFavoritesDoesNotResetTheHomeFolder() throws {
        let navigation = TabNavigationState()
        let home = try [folder(101, name: "Images"), folder(102, name: "À classer")]
        navigation.homePath = home
        navigation.favoritesPath = try [folder(201, name: "Dossier favori")]

        navigation.reset(tab: .favorites)

        XCTAssertEqual(navigation.homePath, home)
        XCTAssertTrue(navigation.favoritesPath.isEmpty)
        XCTAssertEqual(navigation.favoritesScrollToTopRequest, 1)
    }

    func testActualScreensAndFolderDestinationsRenderInBothThemesWithoutCredentials() async throws {
        guard TokenStore.current() == nil else {
            XCTFail("Run this rendering test in a clean simulator without account credentials")
            return
        }
        let defaults = UserDefaults.standard
        let oldDrive = defaults.object(forKey: "orvian.drive-id")
        let cacheKey = "home_start_dir_locked_42"
        let oldRoot = defaults.object(forKey: cacheKey)
        defer {
            defaults.set(oldDrive, forKey: "orvian.drive-id")
            defaults.set(oldRoot, forKey: cacheKey)
        }
        defaults.set(try JSONEncoder().encode(DriveFile.root(name: "Accueil de test")), forKey: cacheKey)
        let drive = Drive(id: 42, name: "Drive de test", size: 1024, usedSize: 256, accountId: nil)
        let session = SessionStore()
        session.selectDrive(drive)
        let shell = try XCTUnwrap(session.mainShell)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            MainTabView(drive: drive, session: session, shell: shell).preferredColorScheme(.light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        let home = try [folder(101, name: "Dossier Accueil")]
        let favorites = try [folder(201, name: "Dossier Favoris")]
        shell.navState.homePath = home
        shell.navState.favoritesPath = favorites

        for theme in [ColorScheme.light, .dark] {
            host.rootView = MainTabView(drive: drive, session: session, shell: shell).preferredColorScheme(theme)
            for tab in [AppTab.home, .favorites, .tag, .profile, .settings] {
                shell.tab = tab
                try await Task.sleep(for: .milliseconds(300))
                host.view.layoutIfNeeded()
                XCTAssertEqual(shell.navState.homePath, home)
                XCTAssertEqual(shell.navState.favoritesPath, favorites)
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "iPad-\(tab.rawValue)-\(theme == .dark ? "sombre" : "clair")-sans-compte"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
