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

function descendants(value) {
    if (!value || typeof value !== 'object') return [];
    return [value, ...(value.children || []).flatMap(descendants)];
}

function hasClass(value, className) {
    return String(value?.attrs?.class || '').split(/\s+/).includes(className);
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

const summary = {
    binary_found: true,
    binary_path: '/opt/xray/current/xray',
    binary_version: 'Xray 26.7.28 exact-backend-value',
    stored_count: 2,
    running_count: 1,
    service_enabled: false,
    legacy_running: false,
    hardware: {
        temperature_available: true,
        temperature_millidegrees: 51250,
        cpu_available: true,
        cpu_total_ticks: 10000,
        cpu_idle_ticks: 8000,
        power_status_available: true,
        undervoltage_now: false,
        undervoltage_occurred: true
    }
};
const firstProfiles = [
    {
        id: 'plain', name: 'Plain', filename: 'plain.json', running: false,
        protocol_stack: 'VLESS + REALITY + Vision',
        autostart: false, geodata: { requires_geoip: false, requires_geosite: false, missing: [] },
        traffic: { available: false, reason: 'stopped', rx_bytes: 0, tx_bytes: 0 }
    },
    {
        id: 'geo', name: 'Geo', filename: 'geo.json', running: true, pid: 4242,
        protocol_stack: 'VLESS + gRPC + REALITY',
        respawn_count: 1, autostart: true,
        geodata: { requires_geoip: true, requires_geosite: false, missing: ['geoip.dat'] },
        traffic: {
            available: true, bytes_available: true, rtt_available: true,
            sample_time: 100, connections: 2,
            rx_bytes: 1000, tx_bytes: 2000, rtt_ms: 17, uptime_seconds: 3661
        }
    }
];
const root = profileView.render({
    ok: true,
    profiles: firstProfiles,
    summary
});

const renderedText = textContent(root);
const renderedNodes = descendants(root);
const headerText = renderedNodes.filter(value => value.tag === 'th').map(textContent).join(' | ');
assert(renderedText.includes('/opt/xray/current/xray'), 'view renders the exact backend binary path');
assert(renderedText.includes('Xray 26.7.28 exact-backend-value'), 'view renders the exact backend binary version');
assert(renderedText.includes('Температура:') && renderedText.includes('51.3 °C'),
    'summary card renders Raspberry Pi temperature with one decimal place');
const cpuStatus = renderedNodes.find(value => hasClass(value, 'xray-hardware-cpu'));
assert(cpuStatus && textContent(cpuStatus).includes('CPU:') && textContent(cpuStatus).includes('—'),
    'first hardware sample waits for a truthful CPU utilization delta');
const powerWarnings = renderedNodes.filter(value => hasClass(value, 'xray-power-warning'));
assert(powerWarnings.length === 1 && textContent(powerWarnings[0]).includes('⚡') &&
    String(powerWarnings[0].attrs.title).includes('фиксировалось') && powerWarnings[0].attrs.tabindex === '0',
    'latched undervoltage renders a keyboard-accessible lightning warning');
assert(!renderedText.includes('GeoIP/GeoSite') && !renderedText.includes('assets_found'), 'view has no global geodata health card');
assert(!headerText.includes('Имя файла JSON') && !headerText.includes('Размер') && !headerText.includes('SHA-256'),
    'table removes filename, size, and SHA columns');
assert(headerText.includes('↓ Принято') && headerText.includes('↑ Отправлено') && headerText.includes('Связь'),
    'table uses the reclaimed space for receive, transmit, and connection metrics');
assert(!renderedText.includes('plain.json') && !renderedText.includes('geo.json'),
    'JSON filenames are not visible in the table body');

const profileNames = renderedNodes.filter(value => hasClass(value, 'xray-profile-name'));
assert(profileNames.length === 2 && profileNames.some(value => String(value.attrs.title).includes('geo.json')),
    'profile name exposes its JSON filename through a focusable tooltip');
const protocolStacks = renderedNodes.filter(value => hasClass(value, 'xray-profile-stack'));
assert(protocolStacks.length === 2 && renderedText.includes('VLESS + REALITY + Vision') &&
    renderedText.includes('VLESS + gRPC + REALITY'),
    'profile rows expose the parsed transport and security stack below the name');
const statusIndicators = renderedNodes.filter(value => hasClass(value, 'xray-process-indicator'));
assert(statusIndicators.length === 2 && statusIndicators.some(value => String(value.attrs.title).includes('geoip.dat')),
    'compact process icon tooltip retains profile-specific geodata warnings');
assert(statusIndicators.some(value => String(value.attrs.title).includes('PID: 4242')),
    'compact process icon tooltip includes the exact running PID');
const autostartButtons = renderedNodes.filter(value => hasClass(value, 'xray-autostart-toggle'));
assert(autostartButtons.length === 2 && autostartButtons.some(value => value.attrs['aria-pressed'] === 'true'),
    'autostart is a compact accessible toggle button');
const actionButtons = renderedNodes.filter(value => hasClass(value, 'xray-action-btn'));
assert(actionButtons.length === 14 && actionButtons.every(value => value.attrs.title && value.attrs['aria-label']),
    'row actions use compact accessible icon buttons');
const trafficCells = renderedNodes.filter(value => hasClass(value, 'xray-traffic-cell'));
assert(trafficCells.length === 4 && trafficCells.every(value =>
    descendants(value).some(child => hasClass(child, 'xray-traffic-separator'))),
    'each traffic metric renders rate and total in one inline row');
assert(renderedText.includes('RTT 17 ms') && renderedText.includes('uptime 1 ч 1 мин'),
    'connection cell renders TCP RTT and process uptime');

const tableContainer = renderedNodes.find(value => value.attrs?.id === 'xray-profiles-table');
const statusContainer = renderedNodes.find(value => value.attrs?.id === 'xray-status-container');
profileView.updateView({
    ok: true,
    profiles: [firstProfiles[0], {
        ...firstProfiles[1],
        traffic: {
            ...firstProfiles[1].traffic,
            sample_time: 105,
            rx_bytes: 201000,
            tx_bytes: 102000
        }
    }],
    summary: {
        ...summary,
        hardware: {
            ...summary.hardware,
            cpu_total_ticks: 11000,
            cpu_idle_ticks: 8750
        }
    }
}, statusContainer, tableContainer);
const updatedText = textContent(tableContainer);
const updatedCpuStatus = descendants(statusContainer).find(value => hasClass(value, 'xray-hardware-cpu'));
assert(updatedCpuStatus && textContent(updatedCpuStatus).includes('25.0%'),
    'hardware card derives CPU utilization from consecutive kernel tick samples');
assert(updatedText.includes('320 Kbps') && updatedText.includes('160 Kbps'),
    'poll delta is rendered as per-profile receive and transmit speed');
assert(updatedText.includes('всего 196 KB') && updatedText.includes('всего 99.6 KB'),
    'traffic cells render adaptive per-profile byte totals');

assert(typeof pollCallback === 'function', 'view registers a polling callback');
const firstPoll = pollCallback();
const secondPoll = pollCallback();
assert(listCalls === 1, 'overlapping polls share one in-flight backend request');
resolveList({ ok: true, profiles: [], summary: {} });
await Promise.all([firstPoll, secondPoll]);

console.log('Profiles view runtime tests completed successfully.');
