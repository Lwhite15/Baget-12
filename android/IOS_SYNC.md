# iPhone → Android sync

The Android app mirrors the iPhone app. Every Monday a scheduled task ports the iPhone changes made since the
commit below, then moves this marker forward.

last-synced-ios-commit: 9ace5d01226ba9d46fe975a2d991623b3a83374d

## Not ported, on purpose

Things that only make sense on iPhone (Sign in with Apple, StoreKit, App Store Connect scripts, TestFlight,
iOS widgets and the notification extension) are covered by their Android counterparts instead
(Google sign-in, Play Billing, FCM). List anything else skipped here, with the reason.

- QA walkthrough UI test (BagetUITests, the BagetQA scheme, debug-only friend previews): iPhone test plumbing; Android's
  launch test in .github/workflows/android.yml covers the same screens.
- Pro monthly at $9.99: Android shows Google Play's own prices, nothing hard-coded to change.
- iPhone Duo (foldable) layouts: 4-column grids, side-by-side swipe card and buttons, icon-only sheet bars, the
  brand bar below the status bar. They're built on Apple's iPhone Duo fold APIs; Android keeps its phone layout.
- Daily drop / Today swipe-deck experiment (payoff cards, release countdowns, morning drop time): the iPhone app rolled
  it back to build 251's Today before this sync, so there was nothing to port. Today's swipe deck / grid and endless
  For You (the version that stayed) are ported.
- Settings "Language" row: it opens iOS's per-app language picker; see "Still to do" below.

## Still to do

- Translations (Spanish, French, Korean, Vietnamese, Chinese, Japanese, Thai, Indonesian, Hindi, Filipino). The iPhone
  app's text lives in Baget/Localizable.xcstrings; Android's screens still use plain English strings and send
  "lang": "en" to the server. Porting means moving every screen's text into res/values*/strings.xml and adding
  Android's per-app language setting. Everything else up to the marker above is ported.
