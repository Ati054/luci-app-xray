import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.join(here, '..', 'core', 'root', 'www', 'luci-static', 'resources', 'view', 'xray', 'profiles.js');
const source = fs.readFileSync(sourcePath, 'utf8');

if (!String.prototype.format) {
    String.prototype.format = function(...args) {
        let i = 0;
        return this.replace(/%[sd]/g, () => String(args[i++]));
    };
}

function node(tag, attrs = {}, children = []) {
    if (!Array.isArray(children)) children = [children];
    return {
        tag,
        attrs: attrs || {},
        children: children.filter(v => v !== null && v !== undefined),
        appendChild(child) { this.children.push(child); return child; }
    };
}

function textContent(value) {
    if (typeof value === 'string' || typeof value === 'number') return String(value);
    if (!value) return '';
    return (value.children || []).map(textContent).join(' ');
}

let listCalls = 0;
let resolveList;
const pendingList = new Promise(resolve => { resolveList = resolve; });
const rpc = {
    declare(spec) {
        if (spec.method === 'list') {
            return () => {
                listCalls++;
                return pendingList;
            };
        }
        return () => Promise.resolve({ ok: true });
    }
};

let pollCallback;
const poll = { add(fn) { pollCallback = fn; } };
const view = { extend(value) { return value; } };
const ui = { createHandlerFn(ctx, name) { return () => ctx[name](); }, addNotification() {} };
const dom = { content(target, value) { target.children = value ? [value] : []; } };
const E = (tag, attrs, children) => node(tag, attrs, children);
const translate = value => value;

const factory = new Function('rpc', 'view', 'poll', 'ui', 'dom', 'E', '_', source);
const profileView = factory(rpc, view, poll, ui, dom, E, translate);

function assert(condition, message) {
    if (!condition) {
        console.error(`FAIL: ${message}`);
        process.exit(1);
    }
    console.log(`PASS: ${message}`);
}

assert(profileView.handleSave === null && profileView.handleSaveApply === null && profileView.handleReset === null,
    'RPC-managed page disables generic Apply/Save/Reset handlers');

const root = profileView.render({
    ok: true,
    profiles: [
        { id: 'plain', name: 'Plain', filename: 'plain.json', size: 10, sha256: 'a', running: false, autostart: false, geodata: { requires_geoip: false, requires_geosite: false, missing: [] } },
        { id: 'geo', name: 'Geo', filename: 'geo.json', size: 20, sha256: 'b', running: false, autostart: false, geodata: { requires_geoip: true, requires_geosite: false, missing: ['geoip.dat'] } }
    ],
    summary: {
        binary_found: true,
        binary_path: '/opt/xray/current/xray',
        binary_version: 'Xray 26.7.28 exact-backend-value',
        stored_count: 2,
        running_count: 0,
        service_enabled: false,
        legacy_running: false
    }
});

const renderedText = textContent(root);
assert(renderedText.includes('/opt/xray/current/xray'), 'view renders the exact backend binary path');
assert(renderedText.includes('Xray 26.7.28 exact-backend-value'), 'view renders the exact backend binary version');
assert(!renderedText.includes('GeoIP/GeoSite') && !renderedText.includes('assets_found'), 'view has no global geodata health card');
assert(renderedText.includes('geoip.dat'), 'view warns for a profile that actually requires missing geoip.dat');

assert(typeof pollCallback === 'function', 'view registers a polling callback');
const firstPoll = pollCallback();
const secondPoll = pollCallback();
assert(listCalls === 1, 'overlapping polls share one in-flight backend request');
resolveList({ ok: true, profiles: [], summary: {} });
await Promise.all([firstPoll, secondPoll]);

console.log('Profiles view runtime tests completed successfully.');
