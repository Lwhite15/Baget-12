# Baget

Your own personal squad of AI agents that learns your taste and makes recommendations for you to purchase.
A native iPhone app (SwiftUI, iOS 17+) with a Supabase backend where the agents search the real web with Claude.

## What's in here

| Path | What it is |
|---|---|
| `Baget/` | The iPhone app |
| `Baget/Engine/Backend.swift` | Supabase client: Sign in with Apple, database, functions, photo storage. Session kept in the Keychain. |
| `Baget/Engine/CloudSync.swift` | Syncs your squad, finds, purchases, notifications and friends with the server |
| `supabase/migrations/` | Database: tables, row-level security, friend flows, notification triggers, scheduler, metrics |
| `supabase/functions/` | Server code: `sweep` (web search), `chat`, `read-photo`, `push`, `setup`, `delete-account` |
| `supabase/tests/` | 54 database security checks and 18 server function tests |
| `.github/workflows/backend.yml` | Tests, then deploys the backend to Supabase |
| `.github/workflows/ios.yml` | Compiles the app on GitHub's Macs, then signs it and uploads it to TestFlight |

## How it works

1. You sign in with Apple. Your agents, finds, purchases, taste photos and friends live in your account.
2. Every 15 minutes the database scheduler wakes the `sweep` function. Each agent whose interval has passed
   (every 3 hours by default; you choose in the app) asks Claude to search the web for products that fit its brief.
   Claude returns real listings with links. The server reads each store page for product photos, and Claude
   checks which one shows that exact item (or none, rather than a wrong photo). Then the server scores
   the listings against your taste and size, the same way the app does.
3. New finds become friend-style notifications in your agent's voice. They're pushed to your iPhone right away,
   or held until 8am during quiet hours (restocks and imminent drops still come through).
4. You can talk to an agent: it updates your profile, searches the web live, flags finds and lines up checkout.
5. On each find: **Like** (the agent leans into its brand and traits, feeds it into its next searches as "more like this",
   and watches it if it's sold out or not out yet), **Pass** (with a reason; "not my style" steers searches away), and
   **Buy**, shown only when the find links to the item's own store page.
6. You buy at the store's own site. "I bought it" logs the purchase on the server (for metrics and so agents learn what you buy). The app doesn't show spending totals. Baget never charges anyone.

Signed out, the app still works as a sample tour with built-in sample data.

## Set it up

You need a Mac only if you want to build locally. Without one, GitHub builds the app and TestFlight installs it.
Never paste keys into a chat or commit them. They all go into GitHub secrets.

### 1. Supabase (free tier is enough)

1. Create a project at supabase.com. Save the **database password**.
2. Note the **project ref**: the `xxxx` in `https://xxxx.supabase.co` (Project Settings > General).
3. Copy the public **anon** key (Project Settings > API Keys; the publishable key also works).
4. Create a **personal access token**: your avatar > Account > Access Tokens.
5. Turn on Sign in with Apple: Authentication > Sign In / Providers > Apple > Enable. Under **Client IDs**, enter
   your app's bundle ID (for example `com.yourname.baget`). A native-only app doesn't need the secret key fields.

### 2. Anthropic

Create an API key at console.anthropic.com and add credit. Set a monthly spend limit there too (Settings > Limits),
so a busy month can't surprise you. See Costs below.

### 3. Apple ($99/year Developer Program)

1. **App ID:** developer.apple.com > Certificates, IDs & Profiles > Identifiers > +. Use your bundle ID and tick
   **Sign in with Apple** and **Push Notifications**.
2. **Push key:** Keys > + > tick **Apple Push Notifications service (APNs)**. Download the `.p8` (one chance)
   and note the **Key ID**.
3. **App record:** appstoreconnect.apple.com > Apps > + > New App, with the same bundle ID.
   App Store names are unique; if "Baget" is taken, try "Baget: Personal Squad". The name under the icon stays Baget.
4. **Build key:** App Store Connect > Users and Access > Integrations > App Store Connect API > Team key, **Admin** role.
   Download the `.p8`; note its **Key ID** and **Issuer ID**.

### 4. GitHub secrets

In your private repository: Settings > Secrets and variables > Actions > New repository secret.

| Secret | Value | Used by |
|---|---|---|
| `SUPABASE_PROJECT_REF` | project ref from 1.2 | backend, app |
| `SUPABASE_ANON_KEY` | anon or publishable key from 1.3 | app |
| `SUPABASE_DB_PASSWORD` | database password from 1.1 | backend |
| `SUPABASE_ACCESS_TOKEN` | personal access token from 1.4 | backend |
| `ANTHROPIC_API_KEY` | from step 2 | backend |
| `BAGET_CRON_SECRET` | any long random string you make up (40+ characters) | backend |
| `APPLE_TEAM_ID` | your 10-character Team ID (Membership details) | app, push |
| `BUNDLE_ID` | your bundle ID, e.g. `com.yourname.baget` | app, push |
| `APNS_KEY_ID` | push key's Key ID from 3.2 | push |
| `APNS_KEY_P8_BASE64` | the push `.p8`, base64-encoded | push |
| `ASC_KEY_ID` | build key's Key ID from 3.4 | app |
| `ASC_ISSUER_ID` | Issuer ID from 3.4 | app |
| `ASC_KEY_P8_BASE64` | the build `.p8`, base64-encoded | app |
| `SERPER_API_KEY` | image search key from serper.dev, for product photos (or use `BRAVE_API_KEY` from Brave Search API) | backend |
| `EBAY_CLIENT_ID` | eBay developer App ID (Production keyset); with the secret below, agents search real eBay listings | backend |
| `EBAY_CLIENT_SECRET` | eBay developer Cert ID (Production keyset) | backend |
| `ANTHROPIC_MODEL` | optional; defaults to `claude-sonnet-5-5` | backend |
| `SWEEP_DAILY_CAP` | optional; most sweeps per person per day, default 30 | backend |
| `SWEEP_MAX_SEARCHES` | optional; web searches per sweep, default 6 | backend |

To base64 a `.p8` on Windows (PowerShell): `[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8")) | Set-Clipboard`.
On an iPhone or any device with no command line: open the `.p8` in a text editor and paste its full contents (including the BEGIN and END lines) as the secret. Both workflows accept raw text or base64.
On Mac or Linux: `base64 -i AuthKey_XXXX.p8 | pbcopy` or `base64 -w0 AuthKey_XXXX.p8`.

### 5. Deploy and install

1. **Backend:** Actions > Backend > Run workflow. It tests, applies the database, deploys the functions,
   stores the server secrets and turns on the scheduler. The last step prints `{"result":"scheduled",...}`.
2. **App:** Actions > iOS > Run workflow with "Upload to TestFlight" ticked. 10 to 20 minutes.
3. **Install:** App Store Connect > your app > TestFlight > add yourself as an internal tester, then install
   from the TestFlight app on your iPhone. Sign in with Apple, deploy an agent, and it starts searching right away.

Every push to `main` re-runs the checks. Backend changes redeploy automatically; run the iOS workflow
whenever you want a new build on your phone.

## Product photos

Most big stores (eBay, Edmunds, Carvana, Harrods...) block servers from reading their pages and apps from loading
their images. So for each listing the server runs an image search for the product's exact name (Serper, which returns
Google Images results, or Brave), downloads the top results, and has Claude pick the one that shows that exact item:
same model, generation and colorway (for cars, the same model and trim). The chosen photo is copied into the public
`product-photos` bucket so the app can always load it. If nothing matches, the tile shows the brand letters.

Set it up: sign up at serper.dev, copy the API key, add it as the GitHub secret `SERPER_API_KEY`, then run
Actions > Backend > Run workflow. The last step checks photos for everything already saved.

## Extra data sources

Agents search the web with Claude. Two optional sources make them sharper:

- **Google Shopping (Serper):** with `SERPER_API_KEY`, each run starts with a list of current products, prices and stores
  for the agent's taste. Claude treats them as leads and confirms each on the store's own page, so Buy links stay real.
  The same key powers product photos.
- **eBay (Browse API):** with `EBAY_CLIENT_ID` and `EBAY_CLIENT_SECRET`, each run also pulls real fixed-price eBay listings
  that fit the agent (exact item page, price, photo, and size when the title gives one). They're scored like any other find.
  Free: create a developer account at developer.ebay.com, then Application Keys > create a **Production** keyset.

Search phrases come from each agent's makers, keywords, traits, creators and what you liked, rotating every run.

## Costs

| What | Cost |
|---|---|
| Supabase | Free tier covers a personal squad and a handful of friends |
| Web sweep | About $0.10 to $0.20 per agent per sweep: up to 6 searches at $0.01 each, plus reading the results |
| Product photo search | About $0.001 per listing on Serper (2,500 free searches to start) |
| Product photo check | Under $0.01 per listing (a small Claude model looks at up to 3 candidate photos) |
| Chat message | About $0.01 to $0.05, more when the agent searches the web |
| Reading a taste photo | About $0.01 |
| Apple Developer Program | $99/year |

Example: 5 agents sweeping every 3 hours is 40 sweeps a day, but the daily cap of 30 holds it to about $3 to $6 a day. Change how often agents search
in the app (your icon at the top left > Notifications and background), and cap it with `SWEEP_DAILY_CAP` and your Anthropic spend limit.
Each squad has at most 12 agents, and each agent can be swept by hand at most once every 10 minutes.

## Data and privacy

- Every table has row-level security: people see only their own data, plus what friends deliberately share.
  The app's public key can't read listings, call server functions or touch other accounts (tested in `supabase/tests`).
- Taste photos go to a private storage folder only the owner can read. On the phone they're cached for speed.
- Your session lives in the iPhone Keychain. Server keys (Claude, Apple push) live only in Supabase's secret store.
- Friends see your taste profile only if you allow it, and your purchases only if you turn that on.
- Account deletion (your icon at the top left > Delete my account) permanently removes the account and everything in it.
- Metrics are anonymous, write-only and can be turned off in the app.

## Run the tests yourself

```
# server function tests (Node 22+)
node --experimental-strip-types supabase/tests/functions.test.ts

# database security tests: needs a local Postgres you can create roles in
psql -f supabase/tests/supabase_stub.sql
for f in supabase/migrations/*.sql; do psql -f "$f"; done
psql -f supabase/tests/security_test.sql | grep -E "PASS|FAIL"
```

## Metrics

In the Supabase SQL editor, for example `select * from metrics.monthly_spend;`. Views: `monthly_spend`,
`spend_by_category`, `find_funnel`, `agent_hit_rate`, `pass_reasons`, `notification_engagement`,
`notification_by_voice`, `friend_activity`, `daily_active`, `agents_deployed`, `taste_photos`, `live_sections`.
Sweep costs per run (searches, tokens, errors) are in the `sweep_runs` table.

## Not in this version

- **Buying for you.** Auto-buy needs checkout integrations with retailers and a careful look at each store's
  rules on automated purchasing. Today agents line up checkout and you buy at the store.
