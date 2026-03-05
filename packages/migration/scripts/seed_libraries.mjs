#!/usr/bin/env node
/**
 * Seed STF Libraries Script
 *
 * Downloads UMD builds and .d.ts files from npm packages
 * and inserts them into the stf_library table.
 *
 * Usage:
 *   DATABASE_URL=postgres://... node seed_libraries.mjs
 *
 * Requirements:
 *   npm install pg
 */
import { execSync } from 'child_process';
import { existsSync, mkdirSync, readFileSync, rmSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import pkg from 'pg';

const { Client } = pkg;

const __dirname = dirname(fileURLToPath(import.meta.url));
const TEMP_DIR = join(__dirname, '.tmp_libs');

// Library configurations
const LIBRARIES = [
	{
		name: 'crypto-js',
		npmPackage: 'crypto-js',
		version: '4.2.0',
		umdPath: 'crypto-js.js',
		// Types are in separate @types/crypto-js package
		dtsPackage: '@types/crypto-js',
		dtsVersion: '4.2.2',
		dtsPath: 'index.d.ts'
	},
	{
		name: 'pdf-lib',
		npmPackage: 'pdf-lib',
		version: '1.17.1',
		umdPath: 'dist/pdf-lib.min.js',
		dtsPath: 'cjs/index.d.ts'
	},
	{
		name: 'docx',
		npmPackage: 'docx',
		version: '8.5.0',
		umdPath: 'build/index.umd.js',
		dtsPath: 'build/index.d.ts'
	},
	{
		name: 'xlsx',
		npmPackage: 'xlsx',
		version: '0.18.5',
		umdPath: 'dist/xlsx.full.min.js',
		dtsPath: 'types/index.d.ts'
	},
	{
		name: 'pptxgenjs',
		npmPackage: 'pptxgenjs',
		version: '3.12.0',
		umdPath: 'dist/pptxgen.bundle.js',
		dtsPath: 'types/index.d.ts'
	},
	{
		name: 'fontkit',
		npmPackage: '@pdf-lib/fontkit',
		version: '1.1.1',
		umdPath: 'dist/fontkit.umd.min.js',
		// No .d.ts file available for this package
		dtsPath: null
	}
];

async function downloadLibrary(lib) {
	const packageDir = join(TEMP_DIR, 'node_modules', lib.npmPackage);

	console.log(`Downloading ${lib.name}@${lib.version}...`);

	// Install specific version
	execSync(`npm install ${lib.npmPackage}@${lib.version} --prefix ${TEMP_DIR} --no-save`, {
		stdio: 'pipe'
	});

	// Read UMD file
	const umdFile = join(packageDir, lib.umdPath);
	if (!existsSync(umdFile)) {
		throw new Error(`UMD file not found: ${umdFile}`);
	}
	const code = readFileSync(umdFile);

	// Read .d.ts file (may be in separate @types package)
	let typeDefinitions = '';

	if (lib.dtsPath) {
		let dtsFile;
		if (lib.dtsPackage) {
			// Types are in a separate package (e.g., @types/crypto-js)
			console.log(`  Downloading types from ${lib.dtsPackage}@${lib.dtsVersion}...`);
			execSync(`npm install ${lib.dtsPackage}@${lib.dtsVersion} --prefix ${TEMP_DIR} --no-save`, {
				stdio: 'pipe'
			});
			dtsFile = join(TEMP_DIR, 'node_modules', lib.dtsPackage, lib.dtsPath);
		} else {
			dtsFile = join(packageDir, lib.dtsPath);
		}

		if (!existsSync(dtsFile)) {
			throw new Error(`TypeScript definitions not found: ${dtsFile}`);
		}
		typeDefinitions = readFileSync(dtsFile, 'utf8');
	} else {
		// No TypeScript definitions available
		console.log(`  No TypeScript definitions available for ${lib.name}`);
		typeDefinitions = '// No TypeScript definitions available for this library';
	}

	return { code, typeDefinitions };
}

async function insertLibrary(client, lib, code, typeDefinitions) {
	console.log(`Inserting ${lib.name} into database...`);

	// Use parameterized query to prevent SQL injection
	// Note: code is a Buffer, which pg automatically converts to bytea
	const sql = `
    INSERT INTO stf_library (id, name, version, code, type_definitions, created_at, updated_at)
    VALUES (uuidv7(), $1, $2, $3, $4, NOW(), NOW())
    ON CONFLICT (name) DO UPDATE SET
      version = EXCLUDED.version,
      code = EXCLUDED.code,
      type_definitions = EXCLUDED.type_definitions,
      updated_at = NOW()
  `;

	await client.query(sql, [lib.name, lib.version, code, typeDefinitions]);

	console.log(
		`  Inserted ${lib.name} (${(code.length / 1024).toFixed(1)} KB code, ${(typeDefinitions.length / 1024).toFixed(1)} KB types)`
	);
}

async function main() {
	console.log('STF Library Seeding Script');
	console.log('==========================\n');

	const databaseUrl = process.env.DATABASE_URL;
	if (!databaseUrl) {
		throw new Error('DATABASE_URL environment variable is required');
	}

	// Create temp directory
	if (existsSync(TEMP_DIR)) {
		rmSync(TEMP_DIR, { recursive: true });
	}
	mkdirSync(TEMP_DIR, { recursive: true });

	// Connect to database
	const client = new Client({ connectionString: databaseUrl });
	await client.connect();

	try {
		for (const lib of LIBRARIES) {
			const { code, typeDefinitions } = await downloadLibrary(lib);
			await insertLibrary(client, lib, code, typeDefinitions);
		}

		console.log('\nAll libraries seeded successfully!');
	} finally {
		// Cleanup
		await client.end();
		if (existsSync(TEMP_DIR)) {
			rmSync(TEMP_DIR, { recursive: true });
		}
	}
}

main().catch((err) => {
	console.error('Error:', err.message);
	process.exit(1);
});
