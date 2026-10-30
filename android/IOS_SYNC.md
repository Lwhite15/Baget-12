# iPhone → Android sync

The Android app mirrors the iPhone app. Every Monday a scheduled task ports the iPhone changes made since the
commit below, then moves this marker forward.

last-synced-ios-commit: 6c34a41ad8a6fa1fc1b2ff3ee6a5f33f3dbc0a65

## Not ported, on purpose

Things that only make sense on iPhone (Sign in with Apple, StoreKit, App Store Connect scripts, TestFlight,
iOS widgets and the notification extension) are covered by their Android counterparts instead
(Google sign-in, Play Billing, FCM). List anything else skipped here, with the reason.
