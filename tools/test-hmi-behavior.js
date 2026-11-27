// Exercise the JavaScript from installer-patched QML without Ford's Qt types.
// Updated for session/ready protocol: popup publishes only after native session
// exists, stays stock until two advancing ready replies, returns to stock on
// missing native, DISABLE, session change, mismatch, or timeout.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

const root = process.argv[2];
const read = path => readFileSync(join(root, path), 'utf8').replace(/\r/g, '');
const popup = read('hmirvc/+10inchP/RVCPopup.qml');
const settings = read('hmisettings/driverassistance/+10inchP/RVCSettings.qml');
const disablePath = 'file:///fs/rwdata/yafc/DISABLE';
const confPath = 'file:///fs/rwdata/yafc/camera.conf';
const viewPath = 'file:///fs/tmpfs/yafc-view';
const readyPath = 'file:///fs/tmpfs/yafc-ready';
const sessionPath = 'file:///fs/tmpfs/yafc-session';

function rig(source, files = {}, putError = null) {
    const events = [];
    class XMLHttpRequest {
        open(method, path, asynchronous) {
            assert.equal(asynchronous, false);
            this.method = method;
            this.path = path;
        }
        send(value) {
            this.status = 0; // Qt local-file status alone does not establish success.
            if (this.method === 'PUT') {
                events.push(['PUT', this.path, value]);
                if (putError !== null) { this.status = putError; return; }
                files[this.path] = value;
                this.status = 204;
            }
            this.responseText = files[this.path] ?? '';
        }
        getResponseHeader(name) {
            assert.equal(name, 'Content-Length');
            return this.path in files ? String(this.responseText.length) : '';
        }
    }
    const cameraSource = {
        IPMBRear360: 1, IPMBRearNormal: 2, IPMBRearSplit: 3,
        IPMBFront360: 4, IPMBFrontNormal: 5, IPMBFrontSplit: 6, ZoomLevelMax: 2,
    };
    const instance = vm.createContext({
        XMLHttpRequest, console: { log() {} }, showFrontCamera: true,
        AL2HMIBridge: { RVCSource: cameraSource, rvcSource: { multicameraShowing: 1, rvcZoomLevel: 1 } },
        _hmirvcController: {
            selectRVCView(id) { events.push(['Ford', id]); },
            zoomIn() { events.push(['zoom', 1]); },
            zoomOut() { events.push(['zoom', -1]); },
        },
    });
    for (const [, name, expr] of source.matchAll(/^    (?:readonly )?property \w+ (yafc\w+): (.+)$/gm)) {
        try { instance[name] = vm.runInContext(expr, instance); }
        catch (e) { /* readonly property refs not-yet-set sibling; skip */ }
    }
    for (const fn of source.matchAll(/^    function yafc\w+\([^\n]*\) \{\n[\s\S]*?^    \}/gm))
        vm.runInContext(fn[0], instance);
    for (const name of ['Default', 'Zoom', 'ViewTimeout', 'Cover']) {
        instance[`yafc${name}${name === 'ViewTimeout' ? '' : 'Timer'}`] = {
            running: false,
            restart() { events.push(['start', name]); },
            stop() { events.push(['stop', name]); },
        };
    }
    const views = source.match(/^    readonly property var yafcViews: (\(\{\n[\s\S]+?^    \}\))/m);
    if (views) instance.yafcViews = vm.runInContext(views[1], instance);
    return { instance, events, files, cameraSource };
}

// ---- factory fallback (mode, enabled, DISABLE, failed PUT) ----

for (const conf of ['mode=compose\nenabled=0\n', 'mode=pass\n', '']) {
    const { instance, events } = rig(popup, { [confPath]: conf });
    instance.yafcVisibleChanged(true);
    instance.yafcSelectView('frontwide');
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false);
    assert.deepEqual(events, []);
}

for (const marker of ['', 'disabled by USB\n']) {
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\n', [disablePath]: marker,
    });
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcShown, false);
    assert.deepEqual(events, []);
}

for (const status of [0, 403]) {
    const denied = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\n',
        [sessionPath]: '100.200.300;',
    }, status);
    denied.instance.showFrontCamera = true;
    denied.instance.AL2HMIBridge.rvcSource.multicameraShowing = 4; // IPMBFront360
    denied.instance.yafcFordView = 4;
    denied.instance.yafcVisibleChanged(true);
    assert.equal(denied.instance.yafcShown, false);
    // PUT attempt is emitted; yafcStop may also emit timer stops
    assert.ok(denied.events.some(e => e[0] === 'PUT'), 'PUT attempted on failed write');
}

// ---- no native session → stock, no publish ----

for (const showFront of [true, false]) {
    const { instance, events, files } = rig(popup, { [confPath]: 'mode=compose\nenabled=1\n' });
    instance.showFrontCamera = showFront;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, '', 'no session set without session file');
    assert.equal(instance.yafcShown, false, 'stock when no native session');
    assert.deepEqual(events, [], 'no publish without session');
    // Adding a session file later and re-triggering should pick it up
    files[sessionPath] = '200.300.400;';
    instance.yafcVisibleChanged(false);
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, '200.300.400;', 'session picked up');
}

// session file present but Ford doesn't match → no publish
{
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\n',
        [sessionPath]: '300.400.500;',
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 1; // rear360
    instance.yafcFordView = 1;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, '300.400.500;');
    // Default front key is front360 (ford=4), but Ford shows 1 (rear) → no publish
    assert.equal(instance.yafcShown, false, 'stock when Ford does not match');
    const puts = events.filter(e => e[0] === 'PUT');
    assert.equal(puts.length, 0, 'no publish when Ford mismatches');
}

// ---- yafcDefaultKey returns correct key for each pref ----

const fronts = { front: ['front', 5], front360: ['front360', 4], '360': ['front360only', 4], frontwide: ['frontwide', 6] };
const rears = { rear: ['rear', 2], rear360: ['rear360', 1], '360': ['full360', 1], rearwide: ['wide', 3] };

for (const [pref, [key, ford]] of Object.entries(fronts)) {
    const { instance } = rig(popup);
    instance.showFrontCamera = true;
    instance.yafcFrontViewPref = pref;
    assert.equal(instance.yafcDefaultKey(true), key, `defaultKey front ${pref} → ${key}`);
}
for (const [pref, [key, ford]] of Object.entries(rears)) {
    const { instance } = rig(popup);
    instance.showFrontCamera = false;
    instance.yafcRearViewPref = pref;
    assert.equal(instance.yafcDefaultKey(false), key, `defaultKey rear ${pref} → ${key}`);
}
// Invalid pref falls back to factory default
{
    const { instance } = rig(popup);
    instance.showFrontCamera = true;
    instance.yafcFrontViewPref = 'invalid';
    assert.equal(instance.yafcDefaultKey(true), 'front360', 'invalid front pref → factory fallback');
}

// ---- session protocol: happy path (compose after two advancing ready replies) ----

for (const [pref, [key, ford]] of Object.entries(fronts)) {
    const config = `mode=compose\nenabled=1\nfront_view=${pref}\n`;
    const session = '111.222.333;';
    const { instance, events, files } = rig(popup, {
        [confPath]: config, [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = ford;
    instance.yafcFordView = ford;

    // Open popup: session read, Ford matches → first publish
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, session);
    assert.equal(instance.yafcShown, false, 'still stock after first publish');
    const puts1 = events.filter(e => e[0] === 'PUT');
    assert.equal(puts1.length, 1, 'one PUT on open');
    assert.equal(puts1[0][1], viewPath);
    // Published format: session;seq;compose;16 rects
    const req1 = puts1[0][2];
    assert.match(req1, /^111\.222\.333;\d+;[01];(\d+,){15}\d+\n$/, 'publish format');

    // First ready reply: matching → ack, republish
    files[readyPath] = req1;
    instance.yafcPoll();
    assert.equal(instance.yafcShown, false, 'still stock after first ack');
    const puts2 = events.filter(e => e[0] === 'PUT');
    assert.equal(puts2.length, 2, 'two PUTs after first poll');

    // Second ready reply: match second request → confirmed, apply layout
    files[readyPath] = puts2[1][2]; // second request
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true, 'composed after second ack');
    assert.equal(instance.yafcViewKey, key, `viewKey for ${pref}`);

    // Close: sends off, returns to stock
    const beforeClose = events.length;
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false, 'stock after close');
    assert.equal(instance.yafcSession, '', 'session cleared after close');
    // off PUT should be among new events
    const offPuts = events.slice(beforeClose).filter(e => e[0] === 'PUT');
    assert.ok(offPuts.some(e => e[2].endsWith(';off\n')), 'off sent on close');
}

for (const [pref, [key, ford]] of Object.entries(rears)) {
    const config = `mode=compose\nenabled=1\nrear_view=${pref}\n`;
    const session = '222.333.444;';
    const { instance, events, files } = rig(popup, {
        [confPath]: config, [sessionPath]: session,
    });
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = ford;
    instance.yafcFordView = ford;

    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, session);
    assert.equal(instance.yafcShown, false);
    const req1 = events.filter(e => e[0] === 'PUT')[0][2];

    files[readyPath] = req1;
    instance.yafcPoll();
    const puts2 = events.filter(e => e[0] === 'PUT');
    files[readyPath] = puts2[1][2];
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true);
    assert.equal(instance.yafcViewKey, key, `viewKey for ${pref}`);

    // Close
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false);
    assert.equal(instance.yafcSession, '');
}

// ---- yafcSelectView triggers selectRVCView when Ford differs ----
{
    const session = '555.666.777;';
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4; // IPMBFront360
    instance.yafcFordView = 4;

    // Compose front360
    instance.yafcVisibleChanged(true);
    const req1 = events.filter(e => e[0] === 'PUT')[0][2];
    files[readyPath] = req1;
    instance.yafcPoll();
    const puts2 = events.filter(e => e[0] === 'PUT');
    files[readyPath] = puts2[1][2];
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true);
    assert.equal(instance.yafcViewKey, 'front360');

    // Switch to front (ford=5, different from current ford=4)
    // yafcSelectView should call selectRVCView(5)
    const beforeSwitch = events.length;
    instance.yafcSelectView('front');
    const fordEvents = events.slice(beforeSwitch).filter(e => e[0] === 'Ford');
    assert.equal(fordEvents.length, 1, 'selectView emits Ford event when ford differs');
    assert.deepEqual(fordEvents[0], ['Ford', 5]);

    // Simulate Ford view change: update yafcFordView and call yafcFollowFord
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 5;
    instance.yafcFordView = 5;
    instance.yafcFollowFord();
    // Should publish front view (yafcPendingView is still 'front')
    const newPuts = events.filter(e => e[0] === 'PUT');
    assert.ok(newPuts.length > puts2.length, 'publishes after Ford switch');
}

// ---- failure modes ----

// Timeout: 400ms without ready reply → stop
{
    const session = '888.999.000;';
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;

    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, session);
    // Simulate timeout
    instance.yafcSentAt = Date.now() - 500;
    instance.yafcPoll();
    assert.equal(instance.yafcSession, '', 'session cleared on timeout');
    assert.equal(instance.yafcShown, false, 'stock on timeout');
}

// DISABLE appears mid-session → stop
{
    const session = '111.000.222;';
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;

    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, session);
    // DISABLE marker appears; yafcLoadConfig reads it and returns false
    files[disablePath] = '1';
    instance.yafcPoll();
    assert.equal(instance.yafcSession, '', 'session cleared on DISABLE');
    assert.equal(instance.yafcShown, false, 'stock on DISABLE');
}

// Session file changes (native restart) → stop
{
    const session = '333.444.555;';
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;

    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, session);
    // Session file changes
    files[sessionPath] = '999.888.777;';
    instance.yafcPoll();
    assert.equal(instance.yafcSession, '', 'session cleared on mismatch');
    assert.equal(instance.yafcShown, false, 'stock on session change');
}

// Mismatched ready: reply != request and != lastAck → stay stock (if not yet shown)
{
    const session = '666.777.888;';
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;

    instance.yafcVisibleChanged(true);
    // Write a completely different ready
    files[readyPath] = 'garbage';
    instance.yafcPoll();
    assert.equal(instance.yafcShown, false, 'still stock on mismatched ready');
    assert.ok(instance.yafcSession, 'session persists after mismatched ready (not yet shown)');

    // Mismatched ready while already composed → stop
    // First, compose properly
    files[readyPath] = events.filter(e => e[0] === 'PUT')[0][2];
    instance.yafcPoll();
    const puts2 = events.filter(e => e[0] === 'PUT');
    files[readyPath] = puts2[1][2];
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true, 'composed');

    // Now mismatched ready while shown → stop
    files[readyPath] = 'garbage';
    instance.yafcPoll();
    assert.equal(instance.yafcShown, false, 'stock after mismatched ready while shown');
    assert.equal(instance.yafcSession, '', 'session cleared');
}

// ---- bindings: chrome, height, layout ----

for (const target of ['zoomButton', 'cameraViewButtons', 'pdcImage', 'bottomContainer', 'cancelButton', 'textLabel', 'container']) {
    assert.match(popup, new RegExp(`Binding\\s*\\{\\s*target: ${target}\\b[^}]+when: yafcShown`));
    assert.doesNotMatch(popup, new RegExp(`\\b${target}\\.(?:visible|source|height)\\s*=`));
}
assert.match(popup, /readonly property bool yafcHideChrome: yafcShown && yafcHideChromePref/);
assert.match(popup, /if \(visible\) \{ stockOpen\(\); \} else \{ stockClose\(\); \}/);
for (const id of ['yafcViewButton', 'yafcPanel', 'yafcZoomInButton', 'yafcZoomOutButton']) {
    const itemEnd = popup.match(new RegExp(`^ {16}id: ${id}\\n[\\s\\S]*?^ {12}\\}(,?)$`, 'm'));
    assert.equal(itemEnd?.[1], ',', `${id} must be comma-separated in rootPopupContents`);
}

// ---- settings ----

assert.match(settings, /property bool yafcEnabled:/);
assert.match(settings, /property bool yafcHideChrome:/);
const prefs = rig(settings, { [confPath]: 'enabled=0\nhide_chrome=0\nmode=pass\nview=rear360\n# keep\nfront_view=frontwide\n' });
prefs.instance.yafcLoadConfig();
assert.equal(prefs.instance.yafcEnabled, false);
assert.equal(prefs.instance.yafcHideChrome, false);
assert.equal(prefs.instance.yafcFrontView, 'frontwide');
const toggles = [...settings.matchAll(/onToggleButtonClicked: \{([\s\S]+?)\}/g)];
assert.equal(toggles.length, 2);
for (const [, handler] of toggles) vm.runInContext(handler, prefs.instance);
assert.equal(prefs.instance.yafcEnabled, true);
assert.equal(prefs.instance.yafcHideChrome, true);
assert.match(prefs.files[confPath], /\benabled=1\nhide_chrome=1\nmode=compose\nfront_view=frontwide\n/);
assert.match(prefs.files[confPath], /\bview=rear360\n# keep\n/);
