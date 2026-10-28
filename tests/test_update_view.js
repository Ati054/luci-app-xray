import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '..', 'core', 'root', 'www', 'luci-static', 'resources', 'view', 'xray', 'update.js'), 'utf8');

function requireText(fragment, description) {
    if (!source.includes(fragment)) {
        throw new Error(`Missing ${description}: ${fragment}`);
    }
    console.log(`PASS: ${description}`);
}

new Function(source);
requireText("var helper = '/usr/libexec/xray-update'", 'the UI calls only the packaged updater helper');
requireText("command('status')", 'the UI loads update state without changing the device');
requireText("run('check')", 'the UI exposes an asynchronous signed-release check');
requireText("run('github-start')", 'the UI exposes the verified download/install action');
requireText("poll.add(refresh, 3)", 'the UI polls RAM-backed progress');
requireText('refreshInFlight', 'the UI coalesces overlapping status polls');
requireText('pending && !force', 'the UI pauses polling while an action RPC is pending');
requireText('Профили сохраняются', 'the UI states the profile preservation contract');
requireText('подпись релиза, архитектура, размер и SHA-256', 'the UI explains the verification boundary');

if (/innerHTML|insertAdjacentHTML|document\.write/.test(source))
    throw new Error('Update view must not inject HTML');
if (/ui\.uploadFile|cgi-io/.test(source))
    throw new Error('Update view must not accept an unsigned manual upload');

console.log('UPDATE_VIEW_OK');
