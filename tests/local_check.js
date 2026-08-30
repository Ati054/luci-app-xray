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
    assert(Array.isArray(parsed.outbounds[1].settings.finalRules), 'Outbound 1 has settings.finalRules array');
    assert(parsed.outbounds[1].settings.finalRules[0].action === 'allow', 'finalRules[0].action is allow');
    assert(parsed.outbounds[1].settings.finalRules[0].network === 'tcp,udp', 'finalRules[0].network is tcp,udp');
    assert(parsed.outbounds[1].settings.finalRules[0].ip.includes('!geoip:private'), 'finalRules[0].ip includes !geoip:private');
    assert(parsed.outbounds[2].settings.reverse.tag === 'reverse-raw-in', 'Outbound 2 has reverse-raw-in');
    assert(parsed.outbounds[3].settings.reverse.tag === 'reverse-xhttp-in', 'Outbound 3 has reverse-xhttp-in');
    assert(parsed.routing.rules[0].outboundTag === 'reverse-egress', 'Routing rule 0 targets reverse-egress');
    assert(!parsed.routing.rules[0].ip, 'Routing rule 0 does not define ip matcher (belongs in finalRules)');
    assert(!parsed.routing.rules[0].network, 'Routing rule 0 does not define network matcher (belongs in finalRules)');
} catch (e) {
    assert(false, `Fixture JSON parsing failed: ${e.message}`);
}

// Check Smoke Fixtures
try {
    const smokeAPath = path.join(__dirname, 'fixtures', 'profile-smoke-a.json');
    const smokeBPath = path.join(__dirname, 'fixtures', 'profile-smoke-b.json');
    const smokeInvPath = path.join(__dirname, 'fixtures', 'profile-invalid.json');
    const emptyReversePath = path.join(__dirname, 'fixtures', 'empty-reverse.json');

    const smokeA = JSON.parse(fs.readFileSync(smokeAPath, 'utf8'));
    const smokeB = JSON.parse(fs.readFileSync(smokeBPath, 'utf8'));
    const smokeInv = JSON.parse(fs.readFileSync(smokeInvPath, 'utf8'));
    const emptyReverse = JSON.parse(fs.readFileSync(emptyReversePath, 'utf8'));

    assert(smokeA.outbounds.some(o => o.settings && o.settings.reverse && o.settings.reverse.tag === 'reverse-smoke-a-in'), 'Smoke A has valid reverse tag');
    assert(smokeB.outbounds.some(o => o.settings && o.settings.reverse && o.settings.reverse.tag === 'reverse-smoke-b-in'), 'Smoke B has valid reverse tag');
    assert(smokeB.outbounds.some(o => o.streamSettings && o.streamSettings.network === 'xhttp' && o.streamSettings.security === 'reality'), 'Smoke B is XHTTP + REALITY');
    assert([smokeA, smokeB].every(c => c.outbounds.filter(o => o.streamSettings && o.streamSettings.security === 'reality').every(o => /^[A-Za-z0-9_-]{43}$/.test(o.streamSettings.realitySettings.publicKey))), 'REALITY fixtures use canonical X25519 public key encoding');
    assert(smokeInv.inbounds.length === 1 && smokeInv.inbounds[0].port === 1080, 'Smoke Invalid has listening inbound');
    assert(Array.isArray(emptyReverse.routing.rules) && emptyReverse.routing.rules.length === 0, 'Empty reverse fixture omits ineffective routing rules');
} catch (e) {
    assert(false, `Smoke Fixture check failed: ${e.message}`);
}

// Check LuCI JS files syntax
const jsFiles = [
    'core/root/www/luci-static/resources/view/xray/core.js',
    'core/root/www/luci-static/resources/view/xray/profiles.js',
    'core/root/www/luci-static/resources/view/xray/preview.js',
    'core/root/www/luci-static/resources/view/xray/protocol.js',
    'core/root/www/luci-static/resources/view/xray/shared.js',
    'core/root/www/luci-static/resources/view/xray/transport.js'
];

for (const relPath of jsFiles) {
    try {
        const fullPath = path.join(rootDir, relPath);
        const code = fs.readFileSync(fullPath, 'utf8');
        new Function(code);
        assert(true, `Syntax check passed for ${relPath}`);
    } catch (e) {
        assert(false, `Syntax error in ${relPath}: ${e.message}`);
    }
}

// Check JSON files validity
const jsonFiles = [
    'core/root/usr/share/luci/menu.d/luci-app-xray.json',
    'core/root/usr/share/rpcd/acl.d/luci-app-xray.json'
];

for (const relPath of jsonFiles) {
    try {
        const fullPath = path.join(rootDir, relPath);
        const content = fs.readFileSync(fullPath, 'utf8');
        JSON.parse(content);
        assert(true, `JSON valid for ${relPath}`);
    } catch (e) {
        assert(false, `JSON error in ${relPath}: ${e.message}`);
    }
}

// Check Rule Encoding (.agents/rules/strict-developer.md)
const rulePath = path.join(rootDir, '.agents', 'rules', 'strict-developer.md');
if (fs.existsSync(rulePath)) {
    const buffer = fs.readFileSync(rulePath);
    const hasBOM = buffer.length >= 3 && buffer[0] === 0xEF && buffer[1] === 0xBB && buffer[2] === 0xBF;
    assert(!hasBOM, '.agents/rules/strict-developer.md has no UTF-8 BOM');
    const hasCRLF = buffer.includes(0x0D);
    assert(!hasCRLF, '.agents/rules/strict-developer.md is LF-only');
    const startsWithFrontmatter = buffer.length >= 4 &&
        buffer[0] === 0x2D && buffer[1] === 0x2D && buffer[2] === 0x2D && buffer[3] === 0x0A;
    assert(startsWithFrontmatter, '.agents/rules/strict-developer.md starts with "---\\n"');
}

console.log(`\nLocal checks: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
