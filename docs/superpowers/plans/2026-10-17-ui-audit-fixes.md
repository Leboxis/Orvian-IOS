# iPhone / iPad audit corrections

**Goal:** Implement the sixteen findings in the preceding audit, approved by the user's “corrige tout”.
**Architecture:** Preserve the SwiftUI application and existing repositories. Fix shared controls first; adapt presentation using actual container width without rewriting saved preferences.
**Tech stack:** SwiftUI / UIKit, iOS 26; no new dependencies.
**Spec:** The sixteen-point audit in this conversation.

## Constraints and review focus
- Keep mutations, confirmations, upload validation and privacy protections intact.
- Narrow windows, accessibility text, keyboard, simultaneous transfers and long names must remain usable.
- Windows cannot run UIKit or Xcode; distinguish source checks from native validation.
- No commits or dependency changes required.

## Work
- [x] Cards: accessible activation/selection/menu actions, 44pt favorites, named tags, readable filenames.
- [x] Layout: width- and text-aware phone columns; distinct iPad density levels. Removed misleading exact-column preview.
- [x] Profile: distinguish failed refresh from empty data; retry while preserving cached results.
- [x] Onboarding: bounded width, scrollable and expandable help.
- [x] Navigation: stable tab order/symbols/copy; named navigation menu at accessibility text sizes.
- [x] Chrome: shared safe-area reservation, simultaneous transfer handling, add action in toolbar.
- [x] Browsing: adaptive search, explicit scope, compact action menu, parent navigation and keyboard actions.
- [x] Files: native button keyboard activation and validated external file drop via the existing upload pipeline.
- [x] Empty states: contextual recovery and reset actions.
- [x] Viewer: stacked title/actions, accessible copy, 44pt controls and dark scrims behind meaningful icons.
- [x] Verification: behavioral layout/drop/recent tests, Python regression suite, source review and native regression checklist.
- [ ] Native verification: Xcode build, hosted UIKit tests and device visual/accessibility checks require macOS/iOS.

## Validation
Run the repository Python regression suite and available Swift checks. Add behavioral iOS tests for changed logic and document native cases: iPhone compact/large, iPad 1024×1366 and 1366×1024, compact windows, VoiceOver, Dynamic Type, keyboard and concurrent transfers. Review all final diffs before reporting.

## Verification evidence
- `python -m unittest discover -s Tests -p "test_*.py"`: 38 passing.
- `check_adaptive_ui.py`: compiled production Swift layout and file staging checks pass on Windows.
- `check_recent_sharing.py`: production loader races, isolation, errors and cached error recovery pass.
- `check_audit_regressions.py`: production restoration, mutation, upload cleanup and sharing checks pass.
- `check_motion_and_isolation.py` and `check_performance_regressions.py`: pass.
- Swift parser accepts the application and hosted iOS test sources; this is not SDK typechecking.
- Independent read-only review: no actionable important/critical findings.
- `check_concurrency.py`: blocked on Windows by its explicit `AMD64-apple-macosx14.0` target; left unchanged for macOS CI.
- Existing Swift warnings in `FileGridViewModel.applyCategoryChange` and `UploadSessionCleanup.transmit` remain outside this UI task.

No dependency added; no commit or push performed. Shell safe-area reservations now use rendered height rather than static per-screen offsets; verify scroll anchoring at the end of a list while transfers appear/disappear on device.
