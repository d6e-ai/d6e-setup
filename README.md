# D6E Setup

Configuration files and database schema for deploying [D6E](https://github.com/d6e-ai/d6e) platform instances.

## Contents

```
.env.example                          # Environment variables template (incl. STF Docker)
compose.yml                           # Docker Compose (external DB, Caddy HTTPS; API mounts docker.sock for STF)
packages/migration/
  seed.sql                            # Database schema
  scripts/
    seed_fonts.mjs                    # Seed font data for PDF generation
    seed_libraries.mjs                # Seed JS libraries for STF execution
```

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
cd packages/migration && npm install pg
DATABASE_URL="..." node scripts/seed_fonts.mjs
DATABASE_URL="..." node scripts/seed_libraries.mjs
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

## Documentation

For detailed setup instructions, see [D6E Setup Skills](https://github.com/d6e-ai/d6e-setup-skills).

## License

[Add license information]
