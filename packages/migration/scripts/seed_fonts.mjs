#!/usr/bin/env node
/**
 * Seed Fonts Script
 *
 * Downloads font files and inserts them into the stf_library table
 * for use in PDF generation with Japanese text support.
 *
 * Usage:
 *   DATABASE_URL=postgres://... node seed_fonts.mjs
 *
 * Requirements:
 *   npm install pg
 */
import { createWriteStream, existsSync, mkdirSync, readFileSync, rmSync } from 'fs';
import { get } from 'https';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import pkg from 'pg';

const { Client } = pkg;

const __dirname = dirname(fileURLToPath(import.meta.url));
const TEMP_DIR = join(__dirname, '.tmp_fonts');

// Font configurations
// Using M+ 1p Regular - smaller file size (~2MB vs ~10MB) for faster loading
const FONTS = [
	{
		name: 'mplus-1p-regular',
		displayName: 'M+ 1p Regular (Japanese Font)',
		url: 'https://github.com/google/fonts/raw/main/ofl/mplus1p/MPLUS1p-Regular.ttf',
		version: '1.063'
	}
];

/**
 * Download file from URL
 */
function downloadFile(url, destination) {
	return new Promise((resolve, reject) => {
		const file = createWriteStream(destination);
		get(url, (response) => {
			if (response.statusCode === 302 || response.statusCode === 301) {
				// Follow redirect
				return downloadFile(response.headers.location, destination).then(resolve).catch(reject);
			}
			if (response.statusCode !== 200) {
				reject(new Error(`Failed to download: ${response.statusCode}`));
				return;
			}
			response.pipe(file);
			file.on('finish', () => {
				file.close();
				resolve();
			});
		}).on('error', (err) => {
			rmSync(destination, { force: true });
			reject(err);
		});
	});
}

async function downloadFont(font) {
	const fontPath = join(TEMP_DIR, `${font.name}.ttf`);

	console.log(`Downloading ${font.displayName}...`);
	await downloadFile(font.url, fontPath);

	if (!existsSync(fontPath)) {
		throw new Error(`Font file not found after download: ${fontPath}`);
	}

	const fontData = readFileSync(fontPath);
	console.log(`  Downloaded ${(fontData.length / 1024 / 1024).toFixed(2)} MB`);

	return fontData;
}

async function insertFont(client, font, fontData) {
	console.log(`Inserting ${font.displayName} into database...`);

	const sql = `
    INSERT INTO stf_library (id, name, version, code, type_definitions, created_at, updated_at)
    VALUES (uuidv7(), $1, $2, $3, $4, NOW(), NOW())
    ON CONFLICT (name) DO UPDATE SET
      version = EXCLUDED.version,
      code = EXCLUDED.code,
      updated_at = NOW()
  `;

	// type_definitions contains metadata about the font
	const metadata = JSON.stringify({
		type: 'font',
		format: 'ttf',
		displayName: font.displayName,
		usage: 'Use with pdf-lib: pdfDoc.embedFont(fontBytes)'
	});

	await client.query(sql, [font.name, font.version, fontData, metadata]);

	console.log(`  Inserted ${font.name} (${(fontData.length / 1024 / 1024).toFixed(2)} MB)`);
}

async function main() {
	console.log('Font Seeding Script');
	console.log('===================\n');

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
		for (const font of FONTS) {
			const fontData = await downloadFont(font);
			await insertFont(client, font, fontData);
		}

		console.log('\nAll fonts seeded successfully!');
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
