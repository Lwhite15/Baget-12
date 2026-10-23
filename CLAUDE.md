# Working on Baget

- **App builds ship only on Larry's say-so.** Make and commit changes freely, and let the iOS "check" job compile and
  launch-test them, but never run the iOS workflow with `upload=true` (TestFlight) or the "Beta review" workflow until
  Larry explicitly says to publish a build.
- **Server changes go live as usual:** pushing `supabase/**` to main runs the tests and deploys automatically.
- Never paste keys or passwords into chat or commit them; secrets live only in GitHub Actions secrets. The repo is public.
- **Database changes only through migration files.** Add a new file under `supabase/migrations/` (with a timestamp later
  than the newest one) and push; the backend workflow applies it. Never run DDL or `apply_migration` directly against
  the live database: a version that exists there but not in the repo makes every later deploy fail. Read-only queries
  against the live database are fine.
