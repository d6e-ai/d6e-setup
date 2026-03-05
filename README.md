# D6E Setup

Configuration files and database schema for deploying [D6E](https://github.com/d6e-ai/d6e) platform instances.

## Contents

```
.env.example                          # Environment variables template
compose.yml                           # Docker Compose (external DB, Caddy HTTPS)
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

# 3. Apply database schema
psql $DATABASE_URL < packages/migration/seed.sql

# 4. Apply seed data (requires Node.js)
cd packages/migration && npm install pg
DATABASE_URL="..." node scripts/seed_fonts.mjs
DATABASE_URL="..." node scripts/seed_libraries.mjs
cd ../..

# 5. Create Caddyfile for HTTPS
cat > Caddyfile << 'EOF'
your-domain.example.com {
    reverse_proxy frontend:3000
}
EOF

# 6. Start services
docker compose up -d
```

## Documentation

For detailed setup instructions, see [D6E Setup Skills](https://github.com/d6e-ai/d6e-setup-skills).

## License

[Add license information]
