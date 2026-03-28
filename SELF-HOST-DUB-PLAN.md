# Self-Host Dub on Coolify — Implementation Plan

## Context

Deploy [Dub](https://github.com/dubinc/dub) (open-source link management platform) on a Hetzner VPS via Coolify. Dub has no official Docker support and is tightly coupled to Vercel + external SaaS. We make minimal, merge-friendly changes to decouple from Vercel's hosting, Dockerize it, and deploy.

**Architecture:**
```
melanyss/dub fork (GitHub)
    ↓ Coolify pulls + builds Docker image
Hetzner VPS runs 3 containers:
    - MySQL 8.0 (database)
    - ps-http-sim (PlanetScale protocol proxy → MySQL)
    - Dub Next.js app (standalone mode)
    ↓ Coolify's Caddy reverse proxy handles SSL
3 subdomains (Cloudflare DNS → Hetzner IP):
    - go.houseofmartech.com     → short link redirects
    - dub.houseofmartech.com    → dashboard UI
    - api-dub.houseofmartech.com → API
```

**External free-tier services (required — deeply wired into codebase):**
- Tinybird (click analytics, free: 10GB/1000 req/day)
- Upstash Redis (caching, free: 10K cmd/day)
- Upstash QStash (background jobs, free: 500 msg/day)
- GitHub OAuth (login)
- Resend (email — already have account)

**Estimated effort:** 4-5 hours total.

---

## Phase 0: External Service Accounts

### 0.1 — Tinybird (Click Analytics)

**Why:** Every link click is sent to Tinybird (a hosted ClickHouse database). All analytics queries go through Tinybird's SDK. Deeply hardcoded — can't skip.

1. Sign up at https://www.tinybird.co — pick **EU region** (closest to Hetzner)
2. In dashboard → **Tokens** (left sidebar) → copy **Admin token** = `TINYBIRD_API_KEY`
3. Your `TINYBIRD_API_URL` = `https://api.tinybird.co` (EU) or `https://api.us-east.tinybird.co` (US)
4. Upload Dub's analytics schema to your workspace:

   **Option A (web UI, no CLI):**
   - In the repo, look inside `packages/tinybird/`
   - Upload `.datasource` files first (Data Source → "+" → upload), then `.pipe` files
   - Order matters: datasources first, pipes second

   **Option B (CLI, faster):**
   ```bash
   pip install tinybird-cli
   cd packages/tinybird/
   tb auth --token YOUR_ADMIN_TOKEN
   tb push
   ```

### 0.2 — Upstash Redis (Caching)

**Why:** Link metadata is cached in Redis so redirects don't hit the database every time. Uses Upstash's HTTP-based Redis (`@upstash/redis` SDK).

1. Sign up at https://upstash.com
2. **Create Database** → name: `dub-cache` → region: `eu-central-1` (Frankfurt)
3. On the database page → **REST API** section → copy:
   - `UPSTASH_REDIS_REST_URL` (looks like `https://xyz.upstash.io`)
   - `UPSTASH_REDIS_REST_TOKEN`

### 0.3 — Upstash QStash (Background Jobs)

**Why:** Click tracking is async — Dub queues a background job via QStash instead of blocking the redirect.

1. In the same Upstash account → **QStash** in left sidebar (auto-enabled)
2. Copy these three values:
   - `QSTASH_TOKEN`
   - `QSTASH_CURRENT_SIGNING_KEY`
   - `QSTASH_NEXT_SIGNING_KEY`

### 0.4 — GitHub OAuth App

1. Go to https://github.com/settings/applications/new
2. Application name: `Dub (self-hosted)`
3. Homepage URL: `https://dub.houseofmartech.com`
4. Authorization callback URL: `https://dub.houseofmartech.com/api/auth/callback/github`
5. Click **Register application**
6. Copy `GITHUB_CLIENT_ID` → then click **Generate a new client secret** → copy `GITHUB_CLIENT_SECRET`

### 0.5 — Resend (Email)

Already have an account. Use existing `RESEND_API_KEY`.

---

## Phase 1: Fork Code Changes

All changes use an **early-return guard pattern** so the original code stays intact and upstream merges are clean.

### 1.1 — Add standalone output to next.config.js

**File:** `apps/web/next.config.js`

Add `output: "standalone"` to the Next.js config. This makes Next.js produce a self-contained server for Docker.

Also remove/comment the dub.co-specific redirects (the `redirects()` function that maps `app.dub.sh` → `app.dub.co` etc.) — these are for their production infrastructure and will 404 on ours.

### 1.2 — Fix domain constants for non-Vercel environments

**File:** `packages/utils/src/constants/main.ts`

Currently `APP_DOMAIN`, `API_DOMAIN`, `PARTNERS_DOMAIN` check `NEXT_PUBLIC_VERCEL_ENV` and fall back to `localhost:8888`. Outside Vercel, that env var doesn't exist, so everything resolves to localhost.

**Change pattern** (add one line at the top of each, original code stays as fallback):
```ts
export const APP_DOMAIN =
  process.env.NEXT_PUBLIC_APP_URL ||  // ← NEW: self-hosted override
  (process.env.NEXT_PUBLIC_VERCEL_ENV === "production"
    ? `https://app.${process.env.NEXT_PUBLIC_APP_DOMAIN}`
    : // ... rest of original code unchanged
  );
```

Same pattern for `API_DOMAIN`, `APP_DOMAIN_WITH_NGROK`, `PARTNERS_DOMAIN`.

New env vars we'll set:
- `NEXT_PUBLIC_APP_URL=https://dub.houseofmartech.com`
- `NEXT_PUBLIC_API_URL=https://api-dub.houseofmartech.com`

### 1.3 — Guard Vercel Domains API calls (5 files, merge-friendly)

These files call `https://api.vercel.com` to manage custom domains. Without Vercel hosting, they'd fail. Instead of rewriting them, **add an early-return guard** at the top of each function — original code stays intact below.

**Pattern:**
```ts
// At the top of the function, before any existing code:
if (!process.env.PROJECT_ID_VERCEL) {
  return { name: domain, verified: true, /* mock shape */ };
}
// ... original Vercel API code unchanged below ...
```

**Files:**
- `apps/web/lib/api/domains/add-domain-vercel.ts` — guard `addDomainToVercel()` → return `{ name: domain, verified: true }`
- `apps/web/lib/api/domains/remove-domain-vercel.ts` — guard `removeDomainFromVercel()` → return `{}`
- `apps/web/lib/api/domains/verify-domain.ts` — guard `verifyDomain()` → return `{ verified: true }`
- `apps/web/lib/api/domains/get-domain-response.ts` — guard `getDomainResponse()` → return `{ verified: true }`
- `apps/web/lib/api/domains/get-config-response.ts` — guard `getConfigResponse()` → return `{ misconfigured: false, conflicts: [] }`

**Why this approach:** The original code stays intact below the guard. When you pull upstream updates, git merges cleanly — the only diff is the 3-line guard at the top of each function.

### 1.4 — Edge Config (NO changes needed)

The code checks `process.env.NEXT_PUBLIC_IS_DUB` before using Edge Config. We don't set that var → graceful fallback.

### 1.5 — Create Dockerfile

**File:** `Dockerfile` (repo root — new file, never conflicts on merge)

Multi-stage build:
```
Stage 1 (base):    node:20-alpine + corepack enable pnpm
Stage 2 (deps):    Copy package.json + lockfile from all workspaces, pnpm install --frozen-lockfile
Stage 3 (builder): Copy full source, run prisma generate, run next build (with NEXT_PUBLIC_* build args)
Stage 4 (runner):  Copy standalone output + static + public, run with node server.js
```

Key details:
- Uses `pnpm` (project's package manager)
- Must run `pnpm --filter @dub/prisma generate` before `next build`
- `NEXT_PUBLIC_*` env vars must be Docker build args (Next.js inlines them at build time)
- Final image exposes port 3000

### 1.6 — Create production docker-compose

**File:** `docker-compose.production.yml` (repo root — new file, never conflicts)

Services:
1. **mysql** — MySQL 8.0, persistent volume, healthcheck
2. **planetscale-proxy** — `ghcr.io/mattrobenolt/ps-http-sim` (translates PlanetScale HTTP protocol to MySQL)
3. **dub** — Next.js app built from Dockerfile, depends on mysql + proxy, port 3000

---

## Phase 2: Database Initialization

After first deploy, run once:

1. **Create tables** (Prisma push — uses standard MySQL connection):
   ```bash
   docker exec -it <dub-container> npx prisma db push
   ```

2. **Seed the short domain** (so Dub knows which domain handles redirects):
   ```sql
   INSERT INTO Domain (id, slug, verified, `primary`, target, type, createdAt, updatedAt)
   VALUES ('cldefault', 'go.houseofmartech.com', 1, 1, 'https://dub.houseofmartech.com', 'redirect', NOW(), NOW());
   ```

---

## Phase 3: Coolify Deployment

### 3.1 — Create Coolify resource
1. Coolify dashboard → **New Resource** → **Docker Compose**
2. Source: GitHub → repo `melanyss/dub` → branch `self-hosted`
3. Docker Compose path: `docker-compose.production.yml`

### 3.2 — Environment Variables

Set in Coolify. `NEXT_PUBLIC_*` vars must be marked as **build-time**.

```env
# App identity
NEXT_PUBLIC_APP_NAME=Dub
NEXT_PUBLIC_APP_DOMAIN=houseofmartech.com
NEXT_PUBLIC_APP_SHORT_DOMAIN=go.houseofmartech.com
NEXT_PUBLIC_APP_URL=https://dub.houseofmartech.com
NEXT_PUBLIC_API_URL=https://api-dub.houseofmartech.com

# Database (internal Docker network)
MYSQL_ROOT_PASSWORD=<generate strong password>
DATABASE_URL=mysql://root:<same-password>@mysql:3306/dub
PLANETSCALE_DATABASE_URL=http://root:<same-password>@planetscale-proxy:3900/dub

# Tinybird
TINYBIRD_API_KEY=<from step 0.1>
TINYBIRD_API_URL=https://api.tinybird.co

# Upstash
UPSTASH_REDIS_REST_URL=<from step 0.2>
UPSTASH_REDIS_REST_TOKEN=<from step 0.2>
QSTASH_TOKEN=<from step 0.3>
QSTASH_CURRENT_SIGNING_KEY=<from step 0.3>
QSTASH_NEXT_SIGNING_KEY=<from step 0.3>

# Auth
NEXTAUTH_SECRET=<generate: openssl rand -base64 32>
NEXTAUTH_URL=https://dub.houseofmartech.com
GITHUB_CLIENT_ID=<from step 0.4>
GITHUB_CLIENT_SECRET=<from step 0.4>

# Email
RESEND_API_KEY=<existing>
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_PASSWORD=<same as RESEND_API_KEY>

# Cron
CRON_SECRET=<generate: openssl rand -base64 32>
```

### 3.3 — Cloudflare DNS

In Cloudflare → houseofmartech.com → DNS → Add Record:

| Type | Name | Content | Proxy status | TTL |
|------|------|---------|--------------|-----|
| A | `go` | `HETZNER_IP` | DNS only (gray cloud) | Auto |
| A | `dub` | `HETZNER_IP` | DNS only (gray cloud) | Auto |
| A | `api-dub` | `HETZNER_IP` | DNS only (gray cloud) | Auto |

**Use "DNS only" (gray cloud)** — Coolify's Caddy handles SSL via Let's Encrypt. Orange cloud would conflict.

### 3.4 — Coolify domain aliases

On the dub service in Coolify, add all three domains:
- `go.houseofmartech.com`
- `dub.houseofmartech.com`
- `api-dub.houseofmartech.com`

All point to the same container (port 3000). Dub's middleware routes by Host header.

---

## Phase 4: Cron Jobs

Add to VPS crontab (`crontab -e` on the Hetzner server):

```cron
# Click aggregation (every minute) — essential for analytics
* * * * * curl -s -H "Authorization: Bearer YOUR_CRON_SECRET" https://dub.houseofmartech.com/api/cron/streams/update-workspace-clicks > /dev/null

# Domain verification (hourly)
0 * * * * curl -s -H "Authorization: Bearer YOUR_CRON_SECRET" https://dub.houseofmartech.com/api/cron/domains/verify > /dev/null
```

The other 12 crons are for partner programs, payouts, bounties — skip them.

---

## Phase 5: Verification

1. `https://dub.houseofmartech.com` → Dub login page
2. Sign in with GitHub
3. Create a workspace + test short link
4. Visit `https://go.houseofmartech.com/test` → should redirect
5. Check analytics in dashboard (1-2 min delay for Tinybird)

---

## Files Changed Summary

| File | Type | Merge risk |
|------|------|------------|
| `apps/web/next.config.js` | Edit | Low — adding one key + removing redirects |
| `packages/utils/src/constants/main.ts` | Edit | Low — prepending one line per constant |
| `apps/web/lib/api/domains/add-domain-vercel.ts` | Edit | None — 3-line guard at function top |
| `apps/web/lib/api/domains/remove-domain-vercel.ts` | Edit | None — 3-line guard at function top |
| `apps/web/lib/api/domains/verify-domain.ts` | Edit | None — 3-line guard at function top |
| `apps/web/lib/api/domains/get-domain-response.ts` | Edit | None — 3-line guard at function top |
| `apps/web/lib/api/domains/get-config-response.ts` | Edit | None — 3-line guard at function top |
| `Dockerfile` | New | None — doesn't exist upstream |
| `docker-compose.production.yml` | New | None — doesn't exist upstream |

---

## Upstream Sync Strategy

1. Pin the fork to a specific release tag (e.g., latest stable release)
2. When you want to update: `git fetch upstream && git merge upstream/main`
3. Conflicts will only happen in the ~7 edited files, and only if Dub changes the exact lines we touched
4. The early-return guard pattern minimizes this — our changes are 3 lines at function tops, original code untouched
