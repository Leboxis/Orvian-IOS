"""Phone video layout contracts; rendered geometry still needs an iOS device.

These checks prevent overlay chrome and iPad scope regressions, but cannot
validate AVPlayer rendering, rotation, or native gesture arbitration on Windows.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Orvian/Features/Viewer/VideoPlayerView.swift").read_text(encoding="utf-8")
SUPPORT = (ROOT / "Orvian/Features/Viewer/VideoPlayerSupport.swift").read_text(encoding="utf-8")


def section(start, end):
    return PLAYER.split(start, 1)[1].split(end, 1)[0]


class PhoneVideoPlayerTests(unittest.TestCase):
    def test_phone_scope_is_not_a_narrow_ipad_size_class(self):
        self.assertIn("UIDevice.current.userInterfaceIdiom == .phone", PLAYER)
        body = section("    var body: some View {", "        .onAppear {")
        self.assertIn("if isPhone {\n                phonePlayer", body)
        self.assertIn("} else {\n                tabletPlayer", body)

    def test_video_fills_the_page_under_floating_chrome(self):
        phone = section("    private var phonePlayer:", "    private var phoneTopBar:")
        # La vidéo est la seule région de mise en page : titre et console
        # flottent par-dessus. En frères empilés, ils reprendraient une bande
        # de la hauteur (et, en paysage, de la largeur) à la vidéo.
        self.assertNotIn("VStack(spacing: 0)", phone)
        self.assertIn(".overlay(alignment: .top)", phone)
        self.assertIn(".overlay(alignment: .bottom)", phone)
        self.assertIn(".overlay(alignment: .center)", phone)
        self.assertLess(phone.index("videoArea"), phone.index("phoneTopBar"))
        self.assertLess(phone.index("videoArea"), phone.index("phoneBottomChrome"))
        self.assertIn(".frame(maxWidth: .infinity, maxHeight: .infinity)", phone)
        self.assertIn(".clipped()", phone)
        self.assertNotIn("hiddenControlGestureRegions", phone)
        self.assertNotIn("ignoresSafeArea", phone)
        self.assertNotIn(".id(", phone)
        self.assertNotIn(".aspectRatio", phone)
        self.assertEqual(phone.count(".simultaneousGesture(controlRegionGesture)"), 2)
        # Chaque barre reste conditionnelle : masquée, elle ne laisse aucune
        # zone réservée devant la vidéo.
        self.assertIn("if showControls {", phone)
        bottom = section("    private var phoneBottomChrome:", "    private var phoneBottomBar:")
        self.assertIn("if showControls {", bottom)
        self.assertIn("phoneBottomBar", bottom)
        self.assertIn(".simultaneousGesture(controlRegionGesture)", bottom)
        # L'indicateur de tampon ne doit pas avaler le double-tap ±10 s.
        self.assertIn(".allowsHitTesting(false)", phone)

    def test_floating_console_keeps_its_contrast(self):
        # Le fond sombre de la console la détache de l'image qu'elle recouvre
        # désormais, y compris en apparence claire.
        console = section("    private var phoneBottomBar:", "    private var phoneSpeedButton:")
        self.assertIn(".background(Color(uiColor: .secondarySystemBackground)", console)
        self.assertIn(".environment(\\.colorScheme, .dark)", console)
        self.assertIn(".frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 560)", console)

    def test_tablet_keeps_its_existing_controls_and_gestures(self):
        tablet = section("    private var tabletPlayer:", "    // MARK: - Gestion")
        for existing in ["ZStack", "topBar", "bottomBar", "skipFeedbackOverlay",
                         "hiddenControlGestureRegions", ".opacity(showControls ? 1 : 0)",
                         ".allowsHitTesting(showControls)", ".accessibilityHidden(!showControls)"]:
            self.assertIn(existing, tablet)

    def test_video_and_poster_remain_aspect_fit(self):
        self.assertIn("playerLayer.videoGravity = .resizeAspect", SUPPORT)
        self.assertNotIn(".resizeAspectFill", SUPPORT)
        video = section("    private var videoArea:", "    private var preparing:")
        self.assertIn(".scaledToFit()", video)
        self.assertIn("if isBuffering, !isPhone", video)
        self.assertIn("player == nil, !isPhone", video)

    def test_compact_transport_keeps_full_width_timeline_and_touch_targets(self):
        bar = section("    private var phoneBottomBar:", "    private var tabletPlayer:")
        self.assertIn("phoneSkipButton(forward: false)", bar)
        self.assertIn("phoneSkipButton(forward: true)", bar)
        self.assertIn(".frame(width: 44, height: 44)", bar)
        self.assertIn(".accessibilityLabel(forward ?", bar)
        self.assertIn("fullWidthTimeline: isPhone,", PLAYER)
        console = section("    private var phoneBottomBar:", "    private var phoneSpeedButton:")
        self.assertIn("VStack(spacing: 0)", console)
        self.assertLess(console.index("timeControls"), console.index("phoneTransportButtons"))
        self.assertNotIn("HStack", console)
        self.assertNotIn("phoneSpeedButton", console)
        timeline = PLAYER.split("private struct TransportTimeView:", 1)[1]
        self.assertIn("if dynamicTypeSize > .large", timeline)
        self.assertIn("scrubber.overlay(alignment: .bottom)", timeline)
        self.assertIn("timeLabels.allowsHitTesting(false)", timeline)

    def test_phone_console_is_compact_and_transport_stays_symmetric(self):
        console = section("    private var phoneBottomBar:", "    private var phoneSpeedButton:")
        self.assertIn(".secondarySystemBackground", console)
        self.assertIn("RoundedRectangle(cornerRadius: 24", console)
        self.assertIn(".frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 560)", console)
        self.assertEqual(console.count(".padding(.vertical, 4)"), 2)
        self.assertIn(".padding(.horizontal, 16)", console)
        controls = section("    private var phoneTransportButtons:", "    private func phoneSkipButton(")
        self.assertEqual(controls.count("Spacer(minLength: 0)"), 2)
        order = ["muteButton", "phoneSkipButton(forward: false)", "playButton",
                 "phoneSkipButton(forward: true)", "phoneSpeedButton"]
        indices = [controls.index(item) for item in order]
        self.assertEqual(indices, sorted(indices))
        play = section("    private var playButton:", "    private var favoriteButton:")
        self.assertIn(".frame(width: 44, height: 44)", play)
        self.assertIn(".buttonStyle(PhonePlaybackButtonStyle())", PLAYER)

    def test_airplay_is_only_in_the_phone_header_not_the_console(self):
        header = section("    private var phoneTopBar:", "    private var phoneBottomBar:")
        console = section("    private var phoneBottomBar:", "    private var tabletPlayer:")
        self.assertIn("AirPlayButton()", header)
        self.assertNotIn("AirPlayButton()", console)

    def test_shared_chrome_and_scrubber_polish_are_opt_in(self):
        chrome = (ROOT / "Orvian/UI/MediaChrome.swift").read_text(encoding="utf-8")
        self.assertEqual(chrome.count("var isSubtle = false"), 3)
        self.assertIn("MediaTitlePill(name: file.name, isSubtle: true)", PLAYER)
        self.assertIn("MediaTagButton(isSubtle: isPhone)", PLAYER)
        self.assertIn("isSubtle: isPhone", PLAYER)
        scrubber = (ROOT / "Orvian/Features/Viewer/ScrubberBar.swift").read_text(encoding="utf-8")
        self.assertIn("var isRefined = false", scrubber)
        self.assertIn("isRefined ? (isScrubbing ? 8 : 3) : (isScrubbing ? 14 : 7)", scrubber)
        self.assertIn(".frame(height: 46)", scrubber)
        self.assertIn("isRefined: fullWidthTimeline", PLAYER)
        self.assertIn(".accessibilityAdjustableAction", scrubber)

    def test_auto_hide_rechecks_interaction_after_its_delay(self):
        policy = section("    private var phoneControlsMayAutoHide:", "    private func toggleControls()")
        for state in ["transport.wantsPlayback", "player != nil", "!isLoadingVideo",
                      "!isBuffering", "!hasFailedSetup", "!isTouchingControls",
                      "!showTagSheet", "!showPhoneSpeedPicker", "!voiceOverEnabled"]:
            self.assertIn(state, policy)
        self.assertEqual(policy.count("!isPhone || phoneControlsMayAutoHide"), 2)
        self.assertIn('.confirmationDialog("Vitesse de lecture"', PLAYER)
        self.assertIn(".onChange(of: showPhoneSpeedPicker)", PLAYER)

    def test_pagination_retry_is_outside_the_phone_video(self):
        pager = (ROOT / "Orvian/Features/Viewer/MediaPagerView.swift").read_text(encoding="utf-8")
        body = pager.split("    var body: some View {", 1)[1].split(
            "        .statusBarHidden", 1)[0]
        self.assertIn("VStack(spacing: 0)", body)
        self.assertLess(body.index("pagerContent"), body.index("paginationRetryButton"))
        self.assertIn("if usesPhoneVideoRetryRegion, let errorMessage", body)
        self.assertIn("UIDevice.current.userInterfaceIdiom == .phone && currentFile?.isVideo == true", pager)
        self.assertIn("if !usesPhoneVideoRetryRegion, let errorMessage", pager)

    def test_recovery_rebinds_an_existing_player_layer(self):
        update = SUPPORT.split("    func updateUIView(_ uiView: PlayerLayerUIView", 1)[1].split(
            "    final class PlayerLayerUIView", 1)[0]
        self.assertIn("?.player !== player", update)
        self.assertIn("uiView.configure(player: player)", update)


if __name__ == "__main__":
    unittest.main()
