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
assert "previous?.removeAllCachedResponses()" in api, \
    "Deux URLCache ne peuvent pas cohabiter sur le même diskPath"
settings = source("Orvian/Features/Settings/SettingsView.swift")
assert '@AppStorage("networkCacheLimitMB") private var networkCacheLimitMB = 100' in settings
assert "APIClient.shared.applyCacheSettings()" in settings

# --- L'ordre des arguments de FileCardView suit l'ordre de déclaration ----
# Swift synthétise l'initialiseur membre dans l'ordre des propriétés stockées
# et refuse un appel qui avance puis revient en arrière.
card = source("Orvian/Features/Shared/FileCardView.swift")
card_body = card[:card.index("struct FolderColorPickerSheet")]
declarations = [
    line for line in card_body.splitlines()
    if line.startswith("    let ") or line.startswith("    var ")
]
positions = {}
for index, line in enumerate(declarations):
    positions.setdefault(line.split()[1].rstrip(":"), index)
grid_body = source("Orvian/Features/Shared/FileGridView.swift")
call = grid_body[grid_body.index("FileCardView("):]
call = call[:call.index("\n        )")]
label = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*):")
passed = [
    match.group(1)
    for line in call.splitlines()
    if (match := label.match(line))
]
unknown = [name for name in passed if name not in positions]
assert not unknown, "Propriétés de FileCardView inconnues : " + ", ".join(unknown)
assert len(passed) >= 10, "L'appel de FileCardView n'a pas été analysé en entier"
assert passed == sorted(passed, key=positions.__getitem__), \
    "FileCardView est appelé hors de l'ordre de déclaration : " + ", ".join(passed)

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
assert "target == shell.tab || (target.isKeptAlive && shell.visitedTabs.contains(target))" in main_tabs, \
    "Un onglet conservé ne doit être monté qu'à partir de sa première visite"
assert "shell.markVisited(targetTab)" in main_tabs
assert "private(set) var visitedTabs: Set<AppTab> = [.home]" in source("Orvian/App/TabNavigationState.swift")
assert "let floatingBarInset: CGFloat = 130" in source("Orvian/UI/DesignSystem.swift"), \
    "La grille doit réserver la place de la pastille flottante"

# --- Le titre de la visionneuse se mesure sur le conteneur ----------------
chrome = source("Orvian/UI/MediaChrome.swift")
assert "containerWidth" in chrome
assert "availableWidth" not in chrome, "Sonder la pastille liait sa largeur à son padding"
assert ".frame(height: 0)" in chrome, "La sonde doit être bridée en hauteur"

# --- Le double-tap vidéo diffère la bascule des contrôles -----------------
video = source("Orvian/Features/Viewer/VideoPlayerView.swift")
assert "pendingToggleTask" in video
assert "cancelPendingToggle" not in video, "Le rattrapaire clignotant ne doit plus exister"
assert "try await Task.sleep(for: .milliseconds(250))" in video

# --- Garde syntaxique : `return`/`break`/`continue` sortent d'un `defer` ------
# Interdit par Swift (« 'return' cannot transfer control out of a defer
# statement »). Erreur de compilation, donc invisible ici sans Xcode.
def blank(match):
    return "\n" * match.group(0).count("\n")


def strip_noise(text):
    text = re.sub(r'"""(?:.|\n)*?"""', blank, text)
    text = re.sub(r"/\*(?:.|\n)*?\*/", blank, text)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)


TRANSFER = re.compile(r"\b(?:return|break|continue)\b")
hazards = []
for path in every_swift():
    clean = strip_noise(path.read_text(encoding="utf-8"))
    for match in re.finditer(r"\bdefer\s*\{", clean):
        depth, cursor = 1, match.end()
        while cursor < len(clean) and depth:
            if clean[cursor] == "{":
                depth += 1
            elif clean[cursor] == "}":
                depth -= 1
            cursor += 1
        if depth == 0 and TRANSFER.search(clean[match.end():cursor - 1]):
            line = clean[:match.start()].count("\n") + 1
            hazards.append(f"{path.relative_to(ROOT)}:{line}")
assert not hazards, "Transfert de contrôle dans un `defer` : " + ", ".join(hazards)

print("Motion and isolation checks passed")
