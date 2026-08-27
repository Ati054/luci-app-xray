// Local syntax and structure validator for Node.js environments

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');

console.log('=== Local JS/MJS Syntax and Fixture Check ===\n');

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

// Check fixture JSON validity
try {
    const fixturePath = path.join(__dirname, 'fixtures', 'dual_reverse_fixture.json');
    const content = fs.readFileSync(fixturePath, 'utf8');
    const parsed = JSON.parse(content);
    assert(parsed.outbounds.length === 4, 'Fixture has 4 outbounds');
    assert(parsed.outbounds[0].protocol === 'freedom', 'Outbound 0 is default freedom');
    assert(parsed.outbounds[1].tag === 'reverse-egress', 'Outbound 1 is reverse-egress');
    assert(parsed.outbounds[2].settings.reverse.tag === 'reverse-raw-in', 'Outbound 2 has reverse-raw-in');
    assert(parsed.outbounds[3].settings.reverse.tag === 'reverse-xhttp-in', 'Outbound 3 has reverse-xhttp-in');
    assert(parsed.routing.rules[0].ip.includes('!geoip:private'), 'Routing rule has !geoip:private');
} catch (e) {
    assert(false, `Fixture JSON parsing failed: ${e.message}`);
}

console.log(`\nLocal checks: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
