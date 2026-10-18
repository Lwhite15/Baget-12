# Working on Baget

- **App builds ship only on Larry's say-so.** Make and commit changes freely, and let the iOS "check" job compile and
  launch-test them, but never run the iOS workflow with `upload=true` (TestFlight) or the "Beta review" workflow until
  Larry explicitly says to publish a build.
- **Server changes go live as usual:** pushing `supabase/**` to main runs the tests and deploys automatically.
- Never paste keys or passwords into chat or commit them; secrets live only in GitHub Actions secrets. The repo is public.
