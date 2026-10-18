# Working on Baget

- **Nothing goes live without Larry's say-so** (app builds and server changes alike). Make and commit changes freely; pushes only
  run tests (iOS "check" compiles and launch-tests the app; "Backend" runs the database and function tests).
  Only when Larry explicitly says to publish:
  - server: run the Backend workflow manually (`gh workflow run Backend --ref main`), which deploys migrations and functions;
  - app: run the iOS workflow with `upload=true` (TestFlight), then "Beta review" to send it to testers.
- Diagnose, Feedback, Demo account and Admin access workflows don't change the app or server and are fine to run.
- Never paste keys or passwords into chat or commit them; secrets live only in GitHub Actions secrets. The repo is public.
