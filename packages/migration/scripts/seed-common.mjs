/**
 * Shared helpers for the stf_library seed scripts (seed_fonts.mjs, seed_libraries.mjs):
 * temp-dir setup/cleanup and DATABASE_URL-backed pg client lifecycle.
 */
import { existsSync, mkdirSync, rmSync } from 'fs';

import pkg from 'pg';

const { Client } = pkg;

export function resetTempDir(tempDir) {
	if (existsSync(tempDir)) {
		rmSync(tempDir, { recursive: true });
	}
	mkdirSync(tempDir, { recursive: true });
}

export function cleanupTempDir(tempDir) {
	if (existsSync(tempDir)) {
		rmSync(tempDir, { recursive: true });
	}
}

export function requireDatabaseUrl() {
	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		throw new Error('DATABASE_URL environment variable is required');
	}
	return databaseUrl;
}

export async function withDbClient(databaseUrl, fn) {
	const client = new Client({ connectionString: databaseUrl });
	await client.connect();
	try {
		return await fn(client);
	} finally {
		await client.end();
	}
}
