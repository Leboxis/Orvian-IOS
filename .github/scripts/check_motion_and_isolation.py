"""Keep the audited invariants: one motion switch, one network cache, no state
written while the grid renders, bounded tab lifetime, stable viewer title."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

MOTION = ROOT / "Orvian/UI/Motion.swift"


def source(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def every_swift():
    return sorted(ROOT.glob("Orvian/**/*.swift"))


# --- Un seul interrupteur, et tout le monde passe par lui -------------------
motion = MOTION.read_text(encoding="utf-8")
assert "static func animation(_ animation: Animation) -> Animation?" in motion
assert "reduceMotion ? nil : animation" in motion
assert "static func publish(reduceMotion: Bool)" in motion
assert "func reduceMotionGate() -> some View" in motion
assert "reduceMotionGate()" in source("Orvian/App/RootView.swift")

offenders = []
# `Motion.animation(` contains `.animation(`: the lookbehind rejects the wrapped
# form, the lookahead rejects a missing wrapper.
pattern = re.compile(
    r"withAnimation\((?!Motion)"
    r"|withAnimation\s*\{"
    r"|(?<![\w])\.animation\((?!Motion)"
)
for path in every_swift():
    if path == MOTION:
        continue
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if pattern.search(line):
            offenders.append(f"{path.relative_to(ROOT)}:{number}")
assert not offenders, "Animations hors de l'interrupteur : " + ", ".join(offenders)

# --- Un seul cache réseau, piloté par les Réglages -------------------------
assert "URLCache" not in source("Orvian/App/OrvianApp.swift"), \
    "Le doublon de cache réseau doit rester supprimé"
api = source("Orvian/Core/API/APIClient.swift")
assert api.count("URLCache(") == 1, "Un seul URLCache dans le client API"
assert "networkCacheLimitMB" in api
assert "func applyCacheSettings()" in api
assert "currentCacheLimitBytes()" in api
settings = source("Orvian/Features/Settings/SettingsView.swift")
assert '@AppStorage("networkCacheLimitMB")' in settings
assert "APIClient.shared.applyCacheSettings()" in settings

# --- Le cache du filtre ne vit plus dans un @State de la vue ---------------
grid = source("Orvian/Features/Shared/FileGridView.swift")
model = source("Orvian/Features/Shared/FileGridViewModel.swift")
assert "@State private var visibleItemsCache" not in grid
assert "@ObservationIgnored private var visibleItemsCache" in model
assert "func visibleItems(key: VisibleItemsKey, mediaMetadata: MediaMetadataStore)" in model

# --- Une révision de liste et une écriture d'instantané par salve ---------
assert "private var revisionBumpPending = false" in model
assert "if revisionBumpPending {" in model
assert "private var snapshotWriteScheduled = false" in model
assert "func flushPendingSnapshot()" in model
assert model.index("flushPendingSnapshot()\n        if loadedOnce") < model.index("DirectoryListStore.shared.snapshot(")

# --- Préchargement des miniatures en temps constant -----------------------
thumbnails = source("Orvian/Core/Cache/ThumbnailProvider.swift")
assert "guard seen.insert(key).inserted else { continue }" in thumbnails
assert "newestKeys.contains(key)" not in thumbnails

# --- Les préférences sont lues par la grille, pas par chaque carte ---------
card = source("Orvian/Features/Shared/FileCardView.swift")
assert "@AppStorage" not in card, "Une carte ne doit observer aucun réglage"
assert "var showFileSizes = true" in card
assert 'var defaultFolderColor = "#4285F5"' in card
assert "showFileSizes: showFileSizes," in grid
assert "defaultFolderColor: defaultFolderColor," in grid

# --- Onglets conservés, pastille flottante, animation pilotée par la valeur -
tabbar = source("Orvian/UI/FloatingTabBar.swift")
assert "var isKeptAlive: Bool" in tabbar
assert "case .home, .favorites, .tag: return true" in tabbar
assert "case .settings, .profile: return false" in tabbar
assert ".animation(Motion.animation(.snappy(duration: 0.25)), value: selection)" in tabbar
assert "withAnimation(.snappy(duration: 0.25))" not in tabbar
main_tabs = source("Orvian/App/MainTabView.swift")
assert "safeAreaInset(edge: .bottom" not in main_tabs, \
    "La pastille de transfert ne doit plus pousser la grille"
assert "target.isKeptAlive || target == shell.tab" in main_tabs
assert "let floatingBarInset: CGFloat = 130" in source("Orvian/UI/DesignSystem.swift"), \
    "La grille doit réserver la place de la pastille flottante"

# --- Le titre de la visionneuse se mesure sur le conteneur ----------------
chrome = source("Orvian/UI/MediaChrome.swift")
assert "containerWidth" in chrome
assert "availableWidth" not in chrome, "Mesurer la pastille elle-même reboucle"

# --- Le double-tap vidéo diffère la bascule des contrôles -----------------
video = source("Orvian/Features/Viewer/VideoPlayerView.swift")
assert "pendingToggleTask" in video
assert "cancelPendingToggle" not in video, "Le rattrapaire clignotant ne doit plus exister"
assert "try await Task.sleep(for: .milliseconds(250))" in video

print("Motion and isolation checks passed")
