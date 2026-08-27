// Validates that .agents/rules/strict-developer.md is UTF-8 without BOM, LF-only, and starts with exactly "---\n"

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rulePath = path.resolve(__dirname, '..', '.agents', 'rules', 'strict-developer.md');

console.log('=== Test Suite: Rule File Encoding Normalization ===\n');

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

if (!fs.existsSync(rulePath)) {
    console.log(`  [FAIL] Rule file not found: ${rulePath}`);
    process.exit(1);
}

const buffer = fs.readFileSync(rulePath);

// Check 1: No UTF-8 BOM (0xEF, 0xBB, 0xBF)
const hasBOM = buffer.length >= 3 && buffer[0] === 0xEF && buffer[1] === 0xBB && buffer[2] === 0xBF;
assert(!hasBOM, '.agents/rules/strict-developer.md must not contain a UTF-8 BOM');

// Check 2: No CRLF (\r / 0x0D)
const hasCRLF = buffer.includes(0x0D);
assert(!hasCRLF, '.agents/rules/strict-developer.md must be LF-only (no CR / CRLF)');

// Check 3: First bytes are exactly "---\n" (0x2D 0x2D 0x2D 0x0A)
const startsWithFrontmatter = buffer.length >= 4 &&
    buffer[0] === 0x2D && buffer[1] === 0x2D && buffer[2] === 0x2D && buffer[3] === 0x0A;
assert(startsWithFrontmatter, '.agents/rules/strict-developer.md first 4 bytes must be exactly "---\\n"');

console.log(`\nRule encoding checks: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
