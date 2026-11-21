# D6E Setup

Configuration files and database schema for deploying [D6E](https://github.com/d6e-ai/d6e) platform instances.

## Contents

```
.env.example                          # Environment variables template (STF Docker, local LLMs, voice, console origins)
compose.yml                           # Docker Compose (external DB, Caddy HTTPS; API mounts docker.sock for STF)
opensign/                             # Optional same-VPS OpenSign Compose overlay
docs/opensign-compose.md              # OpenSign operations guide
packages/migration/
  seed.sql                            # Database schema for a fresh database
  migrations/                         # Incremental migrations (001–080) for an existing database
  scripts/
    seed_fonts.mjs                    # Seed font data for PDF generation
    seed_libraries.mjs                # Seed JS libraries for STF execution
```

## Versions

These files match **D6E v1.6.0**. `compose.yml` uses the `latest` images, which point to the newest D6E release (`ghcr.io/d6e-ai/d6e-api`, `d6e-mcp`, `d6e-frontend`). To stay on one version, replace `latest` with a release tag such as `v1.6.0`.

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/d6e-ai/d6e-setup.git
cd d6e-setup

# 2. Configure environment
cp .env.example .env
# Edit .env — set DATABASE_URL, D6E_CONTAINER_TOKEN_SECRET, ORIGIN,
# D6E_AUTH_CLIENT_ID, D6E_AUTH_CLIENT_SECRET
# Optional: tune STF Docker execution (STF_DOCKER_MAX_CONCURRENT,
# STF_DOCKER_TIMEOUT_SECS, resource limits) — see .env.example

# 3. Apply database schema
psql $DATABASE_URL < packages/migration/seed.sql

# 4. Apply seed data (requires Node.js)
cd packages/migration && npm install
DATABASE_URL="..." npm run seed:fonts
DATABASE_URL="..." npm run seed:libraries
cd ../..

# 5. Create Caddyfile for HTTPS
cat > Caddyfile << 'EOF'
example.d6e.ai {
	# SvelteKit-served API routes (skills docs). Must come before the general /api/v1 block.
	handle /api/v1/skills/* {
		reverse_proxy frontend:3000
	}

	# Rust API (e.g. same-origin /api/v1/.../files/.../download). Must not hit SvelteKit.
	handle /api/v1/* {
		reverse_proxy api:8080
	}

	handle {
		reverse_proxy frontend:3000
	}
}
EOF
# Replace example.d6e.ai with your domain; set ORIGIN=https://<your-domain> in .env.

# 6. Start services
docker compose up -d
```

Replace `example.d6e.ai` with your real hostname (DNS must point to this server). Caddy still obtains and renews Let’s Encrypt certificates without any extra TLS configuration. Optionally add a line `tls you@example.com` inside the site block to register an ACME contact email with Let’s Encrypt (certificate expiry notices, account issues); omit it if you do not need that.

## Upgrading

1. Pull this repository (`git pull`) and compare `.env.example` with your `.env` for new settings.
2. Apply the new files in `packages/migration/migrations/` in numeric order (only the ones you have not applied yet), for example `psql "$DATABASE_URL" -f packages/migration/migrations/078_add_voice_outbound_workflows.sql`.
3. Pull and restart the images: `docker compose pull && docker compose up -d`.

From v1.5.0 to v1.6.0 there is no database change either: pull and restart the images (step 3). v1.6.0 adds the API that lets each member see and change their own personal settings (SQL approval and memory) in the D6E console. The pinned charts API now only reaches the caller's own charts, as the web app does: another member's chart answers `404`, and the chart type in JSON is lowercase (`bar`, `line`, `pie`, `table`).

From v1.4.0 to v1.5.0 there is no database change either: pull and restart the images (step 3). v1.5.0 adds the API that lets the D6E console connect OAuth SaaS providers to a workspace through D6E Auth.

From v1.3.0 to v1.4.0 there is no database change: pull and restart the images (step 3). v1.4.0 changes some permissions and checks:
- Creating, changing and deleting STFs and effects, creating their versions, and setting or deleting STF secrets are for workspace admins; other members get `403` (they still read and run them).
- Policy conditions are checked when saved: a condition the server cannot evaluate gets `400` instead of being saved. Saved policies are not changed.
- In the web app, connecting and changing SaaS connections and MCP servers is for workspace admins.

From v1.2.x to v1.3.0, use this order instead of steps 2–3:
1. Apply `080_add_policy_group_member_roles.sql` first. It only adds a column, so the running API is not affected, and the v1.3.0 API needs it.
2. Pull and restart the images.
3. Right after that, apply `079_prefix_user_data_constraint_names.sql`. It renames older named constraints to the workspace-prefixed form that v1.3.0 uses. If a new name is already taken, it stops and renames nothing; the header of the file explains how to check first.

## Documentation

For detailed setup instructions, see [D6E Setup Skills](https://github.com/d6e-ai/d6e-setup-skills).

To run OpenSign beside D6E on the same VPS, see
[OpenSign Compose Option](./docs/opensign-compose.md).

## License

[Add license information]
