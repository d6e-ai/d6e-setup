# Database schema and seed scripts

The SQL schema and seed data of D6E, copied from the D6E release named in the top-level [README](../../README.md) (currently v1.7.0; the schema did not change from v1.3.0).

## Layout

- `seed.sql` — the whole schema for a fresh database. Vector-dependent tables (`file_embedding`, `file_embedding_chunk`) are guarded, so it succeeds even when `pgvector` is absent.
- `migrations/*.sql` — numbered, incremental migrations (`001`–`080`) for a database that is already running.
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
