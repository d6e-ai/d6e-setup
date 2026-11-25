# Database schema and seed scripts

The SQL schema and seed data of D6E, copied from the D6E release named in the top-level [README](../../README.md) (currently v2.3.1, which has no schema change; migrations 082–085 of v2.3.0 add columns and tables, and migration 081 of v2.2.0 changes only data).

## Layout

- `seed.sql` — the whole schema for a fresh database. Vector-dependent tables (`file_embedding`, `file_embedding_chunk`) are guarded, so it succeeds even when `pgvector` is absent.
- `migrations/*.sql` — numbered, incremental migrations (`001`–`085`) for a database that is already running.
- `scripts/seed_libraries.mjs`, `scripts/seed_fonts.mjs` — populate the `stf_library` table with STF helper libraries and fonts.

## Applying the schema

There is no migration runner or tracking table.

- **Fresh database**: apply `seed.sql`, then run both seed scripts.
- **Existing database**: apply the migrations you have not applied yet, in numeric order, directly against PostgreSQL (for example with `psql`). Apply them before starting the new images.

## Commands

```sh
npm install
DATABASE_URL="postgres://..." npm run seed:libraries   # STF libraries
DATABASE_URL="postgres://..." npm run seed:fonts       # fonts
```
