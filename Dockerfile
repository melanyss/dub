# ---- Base ----
FROM node:20-alpine AS base
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate
WORKDIR /app

# ---- Dependencies ----
FROM base AS deps
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY apps/web/package.json apps/web/package.json
COPY packages/cli/package.json packages/cli/package.json
COPY packages/email/package.json packages/email/package.json
COPY packages/embeds/core/package.json packages/embeds/core/package.json
COPY packages/embeds/react/package.json packages/embeds/react/package.json
COPY packages/hubspot-app/package.json packages/hubspot-app/package.json
COPY packages/prisma/package.json packages/prisma/package.json
COPY packages/stripe-app/package.json packages/stripe-app/package.json
COPY packages/tailwind-config/package.json packages/tailwind-config/package.json
COPY packages/tsconfig/package.json packages/tsconfig/package.json
COPY packages/ui/package.json packages/ui/package.json
COPY packages/utils/package.json packages/utils/package.json
RUN pnpm install --frozen-lockfile

# ---- Builder ----
FROM base AS builder
COPY --from=deps /app/ ./
COPY . .

# NEXT_PUBLIC_* vars must be available at build time (Next.js inlines them)
ARG NEXT_PUBLIC_APP_NAME
ARG NEXT_PUBLIC_APP_DOMAIN
ARG NEXT_PUBLIC_APP_SHORT_DOMAIN
ARG NEXT_PUBLIC_APP_URL
ARG NEXT_PUBLIC_API_URL
ARG TINYBIRD_API_KEY
ARG TINYBIRD_API_URL
ARG UPSTASH_REDIS_REST_URL
ARG UPSTASH_REDIS_REST_TOKEN
ARG QSTASH_TOKEN
ARG QSTASH_CURRENT_SIGNING_KEY
ARG QSTASH_NEXT_SIGNING_KEY
ARG NEXTAUTH_SECRET
ARG NEXTAUTH_URL
ARG RESEND_API_KEY

ENV NEXT_PUBLIC_APP_NAME=${NEXT_PUBLIC_APP_NAME}
ENV NEXT_PUBLIC_APP_DOMAIN=${NEXT_PUBLIC_APP_DOMAIN}
ENV NEXT_PUBLIC_APP_SHORT_DOMAIN=${NEXT_PUBLIC_APP_SHORT_DOMAIN}
ENV NEXT_PUBLIC_APP_URL=${NEXT_PUBLIC_APP_URL}
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
# Use a parseable but unreachable DATABASE_URL during build
# The real URL is set at runtime via docker-compose environment
ENV DATABASE_URL=mysql://build:build@localhost:3306/dub
ENV TINYBIRD_API_KEY=${TINYBIRD_API_KEY}
ENV TINYBIRD_API_URL=${TINYBIRD_API_URL}
ENV UPSTASH_REDIS_REST_URL=${UPSTASH_REDIS_REST_URL}
ENV UPSTASH_REDIS_REST_TOKEN=${UPSTASH_REDIS_REST_TOKEN}
ENV QSTASH_TOKEN=${QSTASH_TOKEN}
ENV QSTASH_CURRENT_SIGNING_KEY=${QSTASH_CURRENT_SIGNING_KEY}
ENV QSTASH_NEXT_SIGNING_KEY=${QSTASH_NEXT_SIGNING_KEY}
ENV NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
ENV NEXTAUTH_URL=${NEXTAUTH_URL}
ENV RESEND_API_KEY=${RESEND_API_KEY}
# Dummy values for SDKs that initialize at module scope during build
ENV PLAIN_API_KEY=placeholder
ENV STRIPE_SECRET_KEY=sk_test_placeholder
ENV UPSTASH_VECTOR_REST_URL=https://placeholder.upstash.io
ENV UPSTASH_VECTOR_REST_TOKEN=placeholder

RUN pnpm --filter @dub/prisma generate
RUN pnpm --filter web build 2>&1 || (echo "=== BUILD FAILED ===" && cat /app/apps/web/.next/trace 2>/dev/null; exit 1)

# ---- Runner ----
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

COPY --from=builder /app/apps/web/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/apps/web/.next/static ./apps/web/.next/static

USER nextjs
EXPOSE 3000
CMD ["node", "apps/web/server.js"]
