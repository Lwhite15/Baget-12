# iPhone → Android sync

The Android app mirrors the iPhone app. Every Monday a scheduled task ports the iPhone changes made since the
commit below, then moves this marker forward.

last-synced-ios-commit: f5240564108b6b8e99fd4e38d588880370d462f6

## Not ported, on purpose

Things that only make sense on iPhone (Sign in with Apple, StoreKit, App Store Connect scripts, TestFlight,
iOS widgets and the notification extension) are covered by their Android counterparts instead
(Google sign-in, Play Billing, FCM). List anything else skipped here, with the reason.

- QA walkthrough UI test (BagetUITests, the BagetQA scheme, debug-only friend previews): iPhone test plumbing; Android's
  launch test in .github/workflows/android.yml covers the same screens.
- Pro monthly at $9.99: Android shows Google Play's own prices, nothing hard-coded to change.
- Settings "Language" row: it opens iOS's per-app language picker; see "Still to do" below.

## Still to do

- Translations (Spanish, French, Korean, Vietnamese, Chinese, Japanese, Thai, Indonesian, Hindi, Filipino). The iPhone
  app's text lives in Baget/Localizable.xcstrings; Android's screens still use plain English strings and send
  "lang": "en" to the server. Porting means moving every screen's text into res/values*/strings.xml and adding
  Android's per-app language setting. Everything else up to the marker above is ported.
