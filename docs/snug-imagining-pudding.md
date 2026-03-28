# Self-Host Dub on Coolify (Hetzner VPS)

## Context

Melanys wants to run [Dub](https://github.com/dubinc/dub) (open-source link management platform) for free. Dub has no official Docker support and is deeply coupled to Vercel + 4 external SaaS services. The official "self-hosting" guide still requires Tinybird, Upstash, PlanetScale, and Vercel accounts.

**Our approach:** Fork Dub, make minimal code changes to decouple from Vercel's hosting APIs, Dockerize it, and deploy on Coolify. Use free tiers for analytics (Tinybird) and caching (Upstash) since replacing those would require rewriting hundreds of files. Replace PlanetScale with local MySQL (the repo already supports this via `ps-http-sim`).

**Estimated effort:** 4-5 hours total across all phases.

---

## Phase 0: External Service Accounts (Free Tiers)

These are needed because Dub's codebase deeply integrates their SDKs. Replacing them would be a multi-week rewrite.

### 0.1 — Tinybird (Click Analytics)

**Why:** Every time someone clicks a short link, Dub sends that event to Tinybird (a hosted ClickHouse database). The analytics dashboard (clicks by country, device, referrer, etc.) queries Tinybird. This is hardcoded throughout the codebase — can't skip it.

**What to do:**

1. Go to https://www.tinybird.co and sign up (free tier: 10GB data, 1000 API req/day — plenty for personal use)
2. Pick **EU region** (closer to your Hetzner server, which is likely in Germany/Finland)
3. Once in the dashboard, go to **Tokens** (left sidebar) → copy your **Admin token** — this is your `TINYBIRD_API_KEY`
4. Your `TINYBIRD_API_URL` is `https://api.tinybird.co` (for EU) or `https://api.us-east.tinybird.co` (for US)

**Now you need to upload Dub's analytics schema to your Tinybird workspace.** Dub stores its schema definitions as files in `packages/tinybird/` in the repo. There are two ways to do this:

**Option A — Tinybird web UI (no CLI needed):**
1. In your local clone of `melanyss/dub`, look inside `packages/tinybird/`
2. You'll see `.datasource` files (define tables) and `.pipe` files (define queries)
3. In Tinybird dashboard → click **"+"** → **"Data Source"** → upload each `.datasource` file
4. Then click **"+"** → **"Pipe"** → upload each `.pipe` file
5. Order matters: datasources first, then pipes (pipes reference datasources)

**Option B — Tinybird CLI (faster if you have Python):**
1. `pip install tinybird-cli` (or `brew install tinybird-cli`)
2. `cd packages/tinybird/`
3. `tb auth --token YOUR_ADMIN_TOKEN`
4. `tb push` — uploads everything in the right order automatically
5. Done. You can uninstall the CLI after this — it's a one-time setup

### 0.2 — Upstash Redis (Caching + Rate Limiting)

**Why:** Dub caches link metadata in Redis so redirects are fast (no database query on every click). Also used for rate limiting API requests. Uses Upstash's HTTP-based Redis, not standard Redis — the SDK (`@upstash/redis`) is wired throughout the code.

**What to do:**

1. Go to https://upstash.com and sign up (free: 10K commands/day, 256MB — enough for thousands of links)
2. Click **"Create Database"**
3. Name it anything (e.g., `dub-cache`)
4. **Region:** Pick `eu-west-1` (Ireland) or `eu-central-1` (Frankfurt) — close to your Hetzner server
5. Click **"Create"**
6. On the database detail page, scroll to **"REST API"** section
7. Copy **`UPSTASH_REDIS_REST_URL`** (looks like `https://xyz.upstash.io`)
8. Copy **`UPSTASH_REDIS_REST_TOKEN`** (long string)

### 0.3 — Upstash QStash (Background Jobs)

**Why:** When someone clicks a link, Dub doesn't block the redirect to record analytics. Instead it queues a background job via QStash (Upstash's message queue) to process the click asynchronously. Also handles webhook deliveries.

**What to do:**

1. In the same Upstash account, click **"QStash"** in the left sidebar
2. QStash is automatically enabled — no setup needed
3. Copy these three values from the QStash dashboard:
   - **`QSTASH_TOKEN`** — the main auth token
   - **`QSTASH_CURRENT_SIGNING_KEY`** — for verifying incoming webhook signatures
   - **`QSTASH_NEXT_SIGNING_KEY`** — rotated key (Upstash provides both)

### 0.4 — GitHub OAuth App
1. Go to https://github.com/settings/applications/new
2. Application name: `Dub (self-hosted)` (or whatever you want)
3. Homepage URL: `https://dub.houseofmartech.com`
4. Authorization callback URL: `https://dub.houseofmartech.com/api/auth/callback/github`
5. Click "Register application"
6. Note `GITHUB_CLIENT_ID` (shown immediately) and generate + note `GITHUB_CLIENT_SECRET`

### 0.5 — Resend (Email)
Already have an account. Use existing `RESEND_API_KEY`.

---

## Phase 1: Fork Changes

All changes happen in the `melanyss/dub` fork. These are minimal, targeted edits — no core rewrites.

### 1.1 — Add standalone output to next.config.js
**File:** `apps/web/next.config.js`

Add `output: "standalone"` to the Next.js config object. This makes Next.js produce a self-contained server that works in Docker without `node_modules`.

Also remove/comment the Dub-specific redirects (dub.sh → dub.co, app.dub.sh → app.dub.co etc.) since those are for their production infrastructure.

### 1.2 — Fix domain constants for non-Vercel environments
**File:** `packages/utils/src/constants/main.ts`

The current code uses `NEXT_PUBLIC_VERCEL_ENV` to determine URLs:
```ts
export const APP_DOMAIN =
  process.env.NEXT_PUBLIC_VERCEL_ENV === "production"
    ? `https://app.${process.env.NEXT_PUBLIC_APP_DOMAIN}`
    : process.env.NEXT_PUBLIC_VERCEL_ENV === "preview"
      ? `https://preview.${process.env.NEXT_PUBLIC_APP_DOMAIN}`
      : "http://localhost:8888";
```

**Change:** Add a `NEXT_PUBLIC_APP_URL` override that takes precedence. Same for `API_DOMAIN` and `PARTNERS_DOMAIN`. Pattern:
```ts
export const APP_DOMAIN =
  process.env.NEXT_PUBLIC_APP_URL ||
  (process.env.NEXT_PUBLIC_VERCEL_ENV === "production"
    ? `https://app.${process.env.NEXT_PUBLIC_APP_DOMAIN}`
    : ...existing logic...);
```

New env vars:
- `NEXT_PUBLIC_APP_URL` → e.g. `https://app.yourdomain.com`
- `NEXT_PUBLIC_API_URL` → e.g. `https://api.yourdomain.com`
- `NEXT_PUBLIC_PARTNERS_URL` → e.g. `https://partners.yourdomain.com` (optional, skip if not using partners)

### 1.3 — Stub Vercel Domains API (5 files)
These files call `https://api.vercel.com` to manage custom domains. Without Vercel hosting, they'll fail. Stub them to return mock success responses so the app doesn't break.

**Files to modify:**
- `apps/web/lib/api/domains/add-domain-vercel.ts` → return `{ name: domain, verified: true }`
- `apps/web/lib/api/domains/remove-domain-vercel.ts` → return `{ success: true }`
- `apps/web/lib/api/domains/verify-domain.ts` → return `{ verified: true }`
- `apps/web/lib/api/domains/get-domain-response.ts` → `getDomainResponse()` returns `{ verified: true }`
- `apps/web/lib/api/domains/get-config-response.ts` → `getConfigResponse()` returns `{ misconfigured: false, conflicts: [] }`

**Important:** This means custom domain management through Dub's UI won't actually configure DNS. You'll manage domains manually through Coolify's domain settings + your DNS provider. For a single-user setup this is fine.

### 1.4 — Edge Config (NO changes needed)
The code checks `process.env.NEXT_PUBLIC_IS_DUB` before using Edge Config. Since we won't set that env var, it gracefully falls back to defaults.

### 1.5 — Create Dockerfile
**File:** `Dockerfile` (repo root)

Multi-stage build:
```
Stage 1 (base): node:20-alpine + pnpm
Stage 2 (deps): Install all dependencies
Stage 3 (builder): Copy source, run prisma generate, run next build
Stage 4 (runner): Copy standalone output + static + public, run server
```

Key considerations:
- Must use `pnpm` (the project's package manager)
- Must run `pnpm --filter @dub/prisma generate` before build
- Standalone output goes to `apps/web/.next/standalone/`
- Static assets go to `apps/web/.next/static/`
- Public folder goes to `apps/web/public/`
- `NEXT_PUBLIC_*` env vars must be available at BUILD time (Docker build args)

### 1.6 — Create production docker-compose
**File:** `docker-compose.production.yml` (repo root)

Services:
1. **mysql** — MySQL 8.0, persistent volume, `MYSQL_DATABASE=dub`
2. **planetscale-proxy** — `ghcr.io/mattrobenolt/ps-http-sim` (translates PlanetScale HTTP protocol to MySQL)
3. **dub** — The Next.js app (built from Dockerfile), depends on mysql + planetscale-proxy
4. **(optional) minio** — S3-compatible storage for assets

Network: all services on the same Docker network. Dub connects to:
- MySQL via `DATABASE_URL=mysql://root:password@mysql:3306/dub` (for Prisma)
- PlanetScale proxy via `PLANETSCALE_DATABASE_URL=http://root:password@planetscale-proxy:3900/dub` (for app runtime)

Expose only the Dub app port (3000). Coolify's reverse proxy handles SSL + domain routing.

---

## Phase 2: Database Initialization

After the containers are running:

1. **Run Prisma push** (creates all tables):
   ```bash
   docker exec -it dub-app npx prisma db push
   ```
   Uses `DATABASE_URL` (standard MySQL) — not the PlanetScale proxy.

2. **Seed the default short domain:**
   ```sql
   INSERT INTO Domain (id, slug, verified, primary_, target, type, projectId, createdAt, updatedAt)
   VALUES ('cldefault', 'YOUR_SHORT_DOMAIN', 1, 1, 'https://YOUR_APP_DOMAIN', 'redirect', NULL, NOW(), NOW());
   ```

---

## Phase 3: Coolify Deployment

### 3.1 — Create the resource in Coolify
1. In Coolify dashboard → New Resource → Docker Compose
2. Point to GitHub repo: `melanyss/dub`, branch: `self-hosted` (create this branch for your changes)
3. Set the Docker Compose file path to `docker-compose.production.yml`

### 3.2 — Environment Variables
Set ALL of these in Coolify's environment settings. Mark `NEXT_PUBLIC_*` vars as build-time:

**Required:**
```
NEXT_PUBLIC_APP_NAME=Dub
NEXT_PUBLIC_APP_DOMAIN=yourdomain.com
NEXT_PUBLIC_APP_SHORT_DOMAIN=your-short.domain
NEXT_PUBLIC_APP_URL=https://app.yourdomain.com
NEXT_PUBLIC_API_URL=https://api.yourdomain.com

DATABASE_URL=mysql://root:STRONG_PASSWORD@mysql:3306/dub
PLANETSCALE_DATABASE_URL=http://root:STRONG_PASSWORD@planetscale-proxy:3900/dub

TINYBIRD_API_KEY=your_key
TINYBIRD_API_URL=https://api.tinybird.co

UPSTASH_REDIS_REST_URL=your_url
UPSTASH_REDIS_REST_TOKEN=your_token
QSTASH_TOKEN=your_token
QSTASH_CURRENT_SIGNING_KEY=your_key
QSTASH_NEXT_SIGNING_KEY=your_key

NEXTAUTH_SECRET=<generate with: openssl rand -base64 32>
NEXTAUTH_URL=https://app.yourdomain.com

RESEND_API_KEY=your_existing_key
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_PASSWORD=your_resend_api_key

GITHUB_CLIENT_ID=your_id
GITHUB_CLIENT_SECRET=your_secret

CRON_SECRET=<generate with: openssl rand -base64 32>
```

**Optional (skip initially):**
```
STORAGE_ACCESS_KEY_ID=      (for MinIO/S3 — only if you need image uploads)
STORAGE_SECRET_ACCESS_KEY=
STORAGE_ENDPOINT=
STORAGE_BASE_URL=
STORAGE_PUBLIC_BUCKET=
STORAGE_PRIVATE_BUCKET=

NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=   (only if you want payments)
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
```

### 3.3 — Domain Configuration

**Recommended subdomain setup:**
| Subdomain | Purpose | Why |
|-----------|---------|-----|
| `go.houseofmartech.com` | Short link redirects | Clean, memorable, industry standard for branded short links |
| `dub.houseofmartech.com` | Dashboard (login, manage links) | Keeps it organized under your main domain |
| `api-dub.houseofmartech.com` | API endpoints | For n8n/programmatic access |

**Step A — Cloudflare DNS (3 records):**

In Cloudflare dashboard → houseofmartech.com → DNS → Add Record:

| Type | Name | Content | Proxy | TTL |
|------|------|---------|-------|-----|
| A | `go` | `YOUR_HETZNER_IP` | **DNS only** (gray cloud) | Auto |
| A | `dub` | `YOUR_HETZNER_IP` | **DNS only** (gray cloud) | Auto |
| A | `api-dub` | `YOUR_HETZNER_IP` | **DNS only** (gray cloud) | Auto |

**Important: Use "DNS only" (gray cloud), NOT "Proxied" (orange cloud).** Coolify's Caddy needs to handle SSL directly. If Cloudflare proxy is on, it will conflict with Coolify's automatic Let's Encrypt certificates.

If you prefer to keep Cloudflare proxy on (for DDoS protection), you'd need to set Cloudflare SSL mode to "Full (strict)" and manually upload origin certs — but "DNS only" is simpler.

**Step B — Coolify domain aliases:**

In Coolify, on the Dub service container, add all three domains:
- `go.houseofmartech.com`
- `dub.houseofmartech.com`
- `api-dub.houseofmartech.com`

All three point to the same container (port 3000). Dub's middleware routes based on the `Host` header. Coolify's Caddy handles SSL automatically via Let's Encrypt.

**Step C — Update env vars to match:**
```
NEXT_PUBLIC_APP_DOMAIN=houseofmartech.com
NEXT_PUBLIC_APP_SHORT_DOMAIN=go.houseofmartech.com
NEXT_PUBLIC_APP_URL=https://dub.houseofmartech.com
NEXT_PUBLIC_API_URL=https://api-dub.houseofmartech.com
NEXTAUTH_URL=https://dub.houseofmartech.com
```

---

## Phase 4: Cron Jobs

Dub defines 14 cron jobs in `vercel.json`. Without Vercel, these need to be triggered externally.

**Option A (recommended): Use VPS crontab**
Add a crontab on the Hetzner server that `curl`s each endpoint:
```cron
# Essential — click aggregation (every minute)
* * * * * curl -s -H "Authorization: Bearer YOUR_CRON_SECRET" https://dub.houseofmartech.com/api/cron/streams/update-workspace-clicks

# Essential — domain verification (hourly)
0 * * * * curl -s -H "Authorization: Bearer YOUR_CRON_SECRET" https://dub.houseofmartech.com/api/cron/domains/verify
```

Most other crons are for partner programs, payouts, and dub.co-specific features you won't need. Add them later if needed.

**Option B: Use Upstash QStash schedules**
QStash free tier supports scheduled HTTP calls. Configure them via the Upstash dashboard to hit the cron endpoints with the `CRON_SECRET` header.

---

## Phase 5: Verification

1. Open `https://dub.houseofmartech.com` — should see Dub login page
2. Sign in with GitHub OAuth
3. Create a workspace and a test short link
4. Visit `https://go.houseofmartech.com/test` — should redirect to your target URL
5. Check analytics in the Dub dashboard (may take a minute for Tinybird to process)
6. Test API: `curl https://api-dub.houseofmartech.com/links?workspaceId=...` with your API key

---

## Files Changed Summary

| File | Change |
|------|--------|
| `apps/web/next.config.js` | Add `output: "standalone"`, remove dub.co-specific redirects |
| `packages/utils/src/constants/main.ts` | Add `NEXT_PUBLIC_APP_URL` / `NEXT_PUBLIC_API_URL` override |
| `apps/web/lib/api/domains/add-domain-vercel.ts` | Stub → return mock success |
| `apps/web/lib/api/domains/remove-domain-vercel.ts` | Stub → return mock success |
| `apps/web/lib/api/domains/verify-domain.ts` | Stub → return verified |
| `apps/web/lib/api/domains/get-domain-response.ts` | Stub → return verified |
| `apps/web/lib/api/domains/get-config-response.ts` | Stub → return not misconfigured |
| `Dockerfile` (new) | Multi-stage Docker build for the monorepo |
| `docker-compose.production.yml` (new) | MySQL + ps-http-sim + Dub app |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Upstream updates break the fork | Pin to a specific release tag. Merge upstream selectively. |
| Tinybird/Upstash free tier limits hit | For personal/small-team use, unlikely. Monitor usage. |
| `@vercel/functions` waitUntil fails in standalone | Next.js 15 has `after()` as a built-in alternative. Test and swap if needed. |
| Custom domain management doesn't work through UI | Expected. Manage domains via DNS + Coolify. The stub just prevents crashes. |
| QStash callback URL must be publicly accessible | Coolify handles this via the domain + SSL. |
