import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '..', 'core', 'root', 'www', 'luci-static', 'resources', 'view', 'xray', 'logs.js'), 'utf8');

if (!String.prototype.format) {
    String.prototype.format = function(...args) {
        let i = 0;
        return this.replace(/%[sd]/g, () => String(args[i++]));
    };
}

function node(tag, attrs = {}, children = []) {
    if (!Array.isArray(children)) children = [children];
    return {
        tag, attrs: attrs || {}, children: children.filter(v => v != null), textContent: '', value: attrs?.value || '',
        classList: { toggle() {} },
        addEventListener() {},
        appendChild(child) { this.children.push(child); },
        scrollTop: 0, scrollHeight: 0
    };
}

let rpcSpec;
const rpc = { declare(spec) { rpcSpec = spec; return () => Promise.resolve({ ok: true, lines: [], maximum_limit: 500 }); } };
let pollInterval;
const poll = { add(fn, interval) { pollInterval = interval; } };
const view = { extend(value) { return value; } };
const dom = { content(target, children) { target.children = children || []; } };
const ui = { createHandlerFn(ctx, fn) { return typeof fn === 'function' ? fn.bind(ctx) : ctx[fn].bind(ctx); }, addNotification() {} };
const E = (tag, attrs, children) => node(tag, attrs, children);
const L = { bind(fn, ctx) { return fn.bind(ctx); } };
const translate = value => value;

const factory = new Function('rpc', 'view', 'dom', 'poll', 'ui', 'E', 'L', '_', source);
const logsView = factory(rpc, view, dom, poll, ui, E, L, translate);

function assert(condition, message) {
    if (!condition) {
        console.error(`FAIL: ${message}`);
        process.exit(1);
    }
    console.log(`PASS: ${message}`);
}

assert(rpcSpec.object === 'xray_profiles' && rpcSpec.method === 'logs', 'log view uses the read-only xray_profiles.logs RPC method');
assert(source.includes('RAM · logd · максимум %d строк'), 'log view clearly identifies volatile bounded RAM storage');
assert(source.includes("this.allLines = data.lines.slice(-this.limit)"), 'browser snapshot is capped to the selected line limit');
assert(source.includes("E('div', { 'class': 'xray-log-line"), 'log lines render as text nodes instead of injected HTML');
assert(source.includes("this.paused && !force"), 'automatic refresh can be paused during diagnosis');
assert(source.includes("severitySelect") && source.includes("searchInput"), 'log view provides severity and text filters');

logsView.render();
assert(pollInterval === 5, 'log view polls at a bounded five-second interval');
assert(logsView.handleSave === null && logsView.handleSaveApply === null && logsView.handleReset === null,
    'read-only log view disables LuCI configuration actions');

console.log('Logs view runtime tests completed successfully.');
