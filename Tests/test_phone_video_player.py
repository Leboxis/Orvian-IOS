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

    def test_video_is_a_stable_sibling_between_real_chrome_regions(self):
        phone = section("    private var phonePlayer:", "    private var phoneTopBar:")
        self.assertIn("VStack(spacing: 0)", phone)
        self.assertLess(phone.index("phoneTopBar"), phone.index("            videoArea"))
        self.assertLess(phone.index("            videoArea"), phone.index("phoneBottomBar"))
        # Neither opacity-only hidden controls nor a reserved black rail:
        # conditional sibling bars release their layout space when hidden.
        self.assertEqual(phone.count("if showControls {"), 2)
        self.assertNotIn(".overlay", phone)
        self.assertNotIn("hiddenControlGestureRegions", phone)
        self.assertNotIn("ignoresSafeArea", phone)
        self.assertNotIn(".id(", phone)
        self.assertEqual(phone.count(".simultaneousGesture(controlRegionGesture)"), 3)

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

    def test_transport_reflows_without_shrinking_touch_targets(self):
        bar = section("    private var phoneBottomBar:", "    private var tabletPlayer:")
        self.assertIn("ViewThatFits(in: .horizontal)", bar)
        self.assertIn("dynamicTypeSize.isAccessibilitySize", bar)
        self.assertIn("phoneSkipButton(forward: false)", bar)
        self.assertIn("phoneSkipButton(forward: true)", bar)
        self.assertIn(".frame(width: 44, height: 44)", bar)
        self.assertIn(".accessibilityLabel(forward ?", bar)
        self.assertIn("fullWidthTimeline: isPhone && dynamicTypeSize.isAccessibilitySize", PLAYER)

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
