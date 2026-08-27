// Offline unit tests for Xray release checksum parser

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

console.log('=== Test Suite: Xray Checksum Parser Validation ===\n');

let passed = 0;
let failed = 0;

function assert(cond, msg) {
    if (cond) {
        console.log(`  [PASS] ${msg}`);
        passed++;
    } else {
        console.log(`  [FAIL] ${msg}`);
        failed++;
    }
}

export function parseSha256FromDigest(content) {
    if (!content || typeof content !== 'string') return null;
    const lines = content.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
    const sha256Regex = /^[0-9a-fA-F]{64}$/;
    const matches = [];

    for (const line of lines) {
        // Formats:
        // SHA256= <64 hex>
        // SHA2-256= <64 hex>
        // SHA256 (filename) = <64 hex>
        // SHA512= ... (ignore)
        if (line.match(/^SHA256\s*=\s*([0-9a-fA-F]+)$/i)) {
            matches.push(line.match(/^SHA256\s*=\s*([0-9a-fA-F]+)$/i)[1].toLowerCase());
        } else if (line.match(/^SHA2-256\s*=\s*([0-9a-fA-F]+)$/i)) {
            matches.push(line.match(/^SHA2-256\s*=\s*([0-9a-fA-F]+)$/i)[1].toLowerCase());
        } else if (line.match(/^SHA256\s*\([^)]+\)\s*=\s*([0-9a-fA-F]+)$/i)) {
            matches.push(line.match(/^SHA256\s*\([^)]+\)\s*=\s*([0-9a-fA-F]+)$/i)[1].toLowerCase());
        } else if (line.match(/^[0-9a-fA-F]{64}\s+/)) {
            matches.push(line.split(/\s+/)[0].toLowerCase());
        }
    }

    if (matches.length === 0) {
        return null;
    }

    // Check for conflicting multiple SHA-256 lines
    const unique = [...new Set(matches)];
    if (unique.length > 1) {
        throw new Error(`Conflicting multiple SHA-256 lines detected: ${unique.join(', ')}`);
    }

    const sha = unique[0];
    if (!sha256Regex.test(sha)) {
        throw new Error(`Malformed SHA-256 checksum (not 64 hex characters): ${sha}`);
    }

    return sha;
}

const dummyValidHash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// Test 1: SHA256= <64 hex>
{
    const dgst = `MD5= dummy\nSHA256= ${dummyValidHash}\nSHA512= other`;
    const parsed = parseSha256FromDigest(dgst);
    assert(parsed === dummyValidHash, 'Parses SHA256= <64 hex>');
}

// Test 2: SHA2-256= <64 hex>
{
    const dgst = `SHA2-256= ${dummyValidHash}`;
    const parsed = parseSha256FromDigest(dgst);
    assert(parsed === dummyValidHash, 'Parses SHA2-256= <64 hex>');
}

// Test 3: SHA256 (Xray-linux-64.zip) = <64 hex>
{
    const dgst = `SHA256 (Xray-linux-64.zip) = ${dummyValidHash}`;
    const parsed = parseSha256FromDigest(dgst);
    assert(parsed === dummyValidHash, 'Parses BSD-style SHA256 (filename) = <64 hex>');
}

// Test 4: Missing SHA-256 line
{
    const dgst = `MD5= 0123456789abcdef\nSHA512= 0123456789abcdef`;
    const parsed = parseSha256FromDigest(dgst);
    assert(parsed === null, 'Rejects/returns null on missing SHA-256 line');
}

// Test 5: Malformed SHA-256 (too short or invalid chars)
{
    const dgst = `SHA256= 0123456789abcdef_too_short`;
    let caught = false;
    try {
        const parsed = parseSha256FromDigest(dgst);
        if (!parsed) caught = true;
    } catch (e) {
        caught = true;
    }
    assert(caught, 'Rejects malformed non-64-hex SHA-256');
}

// Test 6: Multiple conflicting SHA-256 lines
{
    const dgst = `SHA256= ${dummyValidHash}\nSHA2-256= ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff`;
    let caught = false;
    try {
        parseSha256FromDigest(dgst);
    } catch (e) {
        caught = true;
    }
    assert(caught, 'Rejects multiple conflicting SHA-256 lines');
}

console.log(`\nChecksum parser checks: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
