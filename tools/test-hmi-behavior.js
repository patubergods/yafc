// Exercise the JavaScript from installer-patched QML without Ford's Qt types.
// The popup takes its layout from camera.conf at entry; the native session only
// enables mailbox publishing. A pick is pending until Ford reports the view,
// the 2 s timeout reconciles to Ford's report, and the 100 ms lease renewal
// never touches the cover or the default timer.
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
    let failPut = putError;
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
                if (failPut !== null) { this.status = failPut; return; }
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
        IPMBRear360: 1, IPMBRearNormal: 2, IPMBRearSplit: 3, IPMBRearZoom: 7,
        IPMBFront360: 4, IPMBFrontNormal: 5, IPMBFrontSplit: 6, ZoomLevelMax: 2,
    };
    const instance = vm.createContext({
        XMLHttpRequest, console: { log() {} }, showFrontCamera: true, visible: true,
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
    return { instance, events, files, cameraSource, fail(status) { failPut = status; } };
}

// ---- factory fallback (mode, enabled, DISABLE, failed PUT) ----

for (const conf of ['mode=compose\nenabled=0\n', 'mode=pass\n', '']) {
    const { instance, events } = rig(popup, { [confPath]: conf });
    instance.yafcVisibleChanged(true);
    instance.yafcSelectView('frontwide');
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false);
    // Timer stops are internal; no mailbox write and no Ford action.
    assert.deepEqual(events.filter(e => e[0] === 'PUT' || e[0] === 'Ford' || e[0] === 'zoom'), []);
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
    // The look follows Ford's report even when the mailbox write is refused;
    // the poll retries the write.
    assert.equal(denied.instance.yafcShown, true);
    // PUT attempt is emitted; yafcStop may also emit timer stops
    assert.ok(denied.events.some(e => e[0] === 'PUT'), 'PUT attempted on failed write');
}

// ---- no native session: the layout still comes from camera.conf ----

for (const showFront of [true, false]) {
    const { instance, events, files } = rig(popup, { [confPath]: 'mode=compose\nenabled=1\n' });
    instance.showFrontCamera = showFront;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, '', 'no session set without session file');
    assert.equal(instance.yafcShown, true, 'layout taken from camera.conf without a session');
    assert.deepEqual(events.filter(e => e[0] === 'PUT'), [], 'no publish without session');
    // Adding a session file later and re-triggering should pick it up
    files[sessionPath] = '200.300.400;';
    instance.yafcVisibleChanged(false);
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcSession, '200.300.400;', 'session picked up');
    // The layout already taken without a session is published once it exists.
    instance.AL2HMIBridge.rvcSource.multicameraShowing = showFront ? 4 : 1;
    instance.yafcFordView = showFront ? 4 : 1;
    instance.yafcPoll();
    assert.ok(events.filter(e => e[0] === 'PUT').length > 0, 'publishes once the session appears');
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

// ---- session protocol: happy path (layout, lease renewal, release) ----

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
    assert.equal(instance.yafcShown, true, 'layout taken on open');
    const puts1 = events.filter(e => e[0] === 'PUT');
    assert.equal(puts1.length, 1, 'one PUT on open');
    assert.equal(puts1[0][1], viewPath);
    // Published format: session;seq;compose;16 rects
    const req1 = puts1[0][2];
    assert.match(req1, /^111\.222\.333;\d+;[01];(\d+,){15}\d+\n$/, 'publish format');

    // The session file is the liveness proof; a ready reply is a refinement.
    // The first poll renews the request and stays composed.
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true, 'still composed after the first poll');
    assert.equal(instance.yafcViewKey, key, `viewKey for ${pref}`);
    const puts2 = events.filter(e => e[0] === 'PUT');
    assert.equal(puts2.length, 2, 'two PUTs after first poll');

    // Close: sends off, returns to stock
    const beforeClose = events.length;
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false, 'stock after close');
    assert.equal(instance.yafcSession, '', 'session cleared after close');
    // A valid compose=0 record releases the native lease; the old ";off"
    // sentinel never parsed.
    const offPuts = events.slice(beforeClose).filter(e => e[0] === 'PUT');
    assert.ok(offPuts.some(e => /;\d+;0;(\d+,){15}\d+\n$/.test(e[2])), 'compose=0 release on close');
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
    assert.equal(instance.yafcShown, true, 'layout taken on open');
    const req1 = events.filter(e => e[0] === 'PUT')[0][2];

    files[readyPath] = req1;
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true, 'still composed');
    assert.equal(instance.yafcViewKey, key, `viewKey for ${pref}`);

    // Close
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false);
    assert.equal(instance.yafcSession, '');
}

// ---- selection: pending until Ford reports, then publish and dwell ----
{
    const session = '555.666.777;';
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: session,
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4; // IPMBFront360
    instance.yafcFordView = 4;

    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcShown, true);
    assert.equal(instance.yafcViewKey, 'front360');
    const putsBefore = events.filter(e => e[0] === 'PUT').length;

    // A tap on a different stream closes the row, raises the cover and asks
    // Ford. Nothing is published until Ford reports the new view.
    instance.yafcPanelOpen = true;
    instance.yafcSelectView('front');
    assert.equal(instance.yafcPendingView, 'front');
    assert.equal(instance.yafcPanelOpen, false, 'panel closes on a pick');
    assert.equal(instance.yafcCover, true, 'cover on a cross-stream switch');
    assert.equal(events.filter(e => e[0] === 'PUT').length, putsBefore, 'no publish before the report');
    assert.deepEqual(events.filter(e => e[0] === 'Ford').pop(), ['Ford', 5]);

    // Ford has not reported yet: the key stays pending and the timeout runs.
    instance.yafcCommitPendingView();
    assert.equal(instance.yafcPendingView, 'front');

    // Ford reports the new view: commit publishes, applies and dwells.
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 5;
    instance.yafcFordView = 5;
    instance.yafcCommitPendingView();
    assert.equal(instance.yafcPendingView, '');
    assert.equal(instance.yafcViewKey, 'front');
    assert.ok(events.filter(e => e[0] === 'PUT').length > putsBefore, 'publish on the Ford report');
    assert.ok(events.filter(e => e[0] === 'start' && e[1] === 'Cover').length >= 1, 'dwell starts from the report');
}

// ---- a tap is ignored while the cover is up ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: '556.667.778;',
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;
    instance.yafcVisibleChanged(true);
    instance.yafcCover = true;
    instance.yafcPanelOpen = true;
    const before = events.length;
    instance.yafcSelectView('front');
    assert.deepEqual(events.slice(before).filter(e => e[0] === 'PUT' || e[0] === 'Ford'), []);
    assert.equal(instance.yafcPendingView, '');
    assert.equal(instance.yafcPanelOpen, true, 'a refused tap leaves the row alone');
}

// ---- Zoomed View is the rear stream plus Ford's zoom level ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nrear_view=rear\n',
        [sessionPath]: '557.668.779;',
    });
    assert.equal(instance.yafcViews.zoom.ford, instance.AL2HMIBridge.RVCSource.IPMBRearNormal,
        'Zoomed View keeps the plain rear stream');
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 2; // IPMBRearNormal
    instance.yafcFordView = 2;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcViewKey, 'rear');
    const putsBefore = events.filter(e => e[0] === 'PUT').length;
    const fordsBefore = events.filter(e => e[0] === 'Ford').length;

    instance.yafcSelectView('zoom');
    assert.equal(instance.yafcViewKey, 'zoom', 'same stream: applied at once');
    assert.equal(events.filter(e => e[0] === 'Ford').length, fordsBefore, 'no Ford view call for zoom');
    assert.ok(events.filter(e => e[0] === 'PUT').length > putsBefore, 'zoom layout published');
    assert.deepEqual(events.filter(e => e[0] === 'zoom').pop(), ['zoom', 1], 'Ford zoomed in');
    assert.equal(instance.yafcZoom, true);
    assert.equal(instance.yafcPendingView, '');

    // The level bounced back: one retry, then no command once it matches.
    instance.AL2HMIBridge.rvcSource.rvcZoomLevel = 1;
    instance.yafcSyncZoom();
    assert.deepEqual(events.filter(e => e[0] === 'zoom').pop(), ['zoom', 1], 're-issues zoomIn');
    instance.AL2HMIBridge.rvcSource.rvcZoomLevel = 2; // ZoomLevelMax
    const zoomed = events.filter(e => e[0] === 'zoom').length;
    instance.yafcSyncZoom();
    assert.equal(events.filter(e => e[0] === 'zoom').length, zoomed, 'no command at the max level');
}

// ---- timeout reconcile always drops the cover ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: '558.669.780;',
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;
    instance.yafcVisibleChanged(true);
    instance.yafcSelectView('front'); // ford 5, cover up, pending front

    // Ford never reports: lay out the reported view and dwell the cover.
    instance.yafcReconcile();
    assert.equal(instance.yafcPendingView, '');
    assert.equal(instance.yafcViewKey, 'front360', 'falls back to the reported view');
    assert.ok(events.filter(e => e[0] === 'start' && e[1] === 'Cover').length >= 1, 'cover re-dwells');

    // Nothing matches at all: the cover must come down.
    instance.yafcCover = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 99;
    instance.yafcFordView = 99;
    instance.yafcReconcile();
    assert.equal(instance.yafcCover, false, 'cover drops when Ford reports nothing known');
}

// ---- a failed publish still takes the look; the poll retries the write ----
{
    const r = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nrear_view=rear\n',
        [sessionPath]: '559.670.781;',
    });
    const { instance } = r;
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 2;
    instance.yafcFordView = 2;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcViewKey, 'rear');

    instance.yafcSelectView('wide'); // ford 3: waits for the report
    r.fail(403);
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 3;
    instance.yafcFordView = 3;
    instance.yafcCommitPendingView();
    assert.equal(instance.yafcPendingView, '', 'the report completes the pick');
    assert.equal(instance.yafcViewKey, 'wide', 'look follows Ford even when the write fails');
    assert.equal(instance.yafcRequestedKey, 'rear', 'nothing published yet');

    r.fail(null);
    instance.yafcPoll();
    assert.equal(instance.yafcRequestedKey, 'wide', 'the poll republishes the current view');
}

// ---- the 300 ms default moves to the preference unless the user picked ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nrear_view=rear\n',
        [sessionPath]: '560.671.782;',
    });
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 1; // IPMBRear360
    instance.yafcFordView = 1;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcViewKey, 'rear360', 'entry keeps the reported view');
    const fordsBefore = events.filter(e => e[0] === 'Ford').length;
    instance.yafcApplyDefault();
    assert.equal(instance.yafcPendingView, 'rear');
    assert.equal(instance.yafcCover, true);
    assert.deepEqual(events.filter(e => e[0] === 'Ford').pop(), ['Ford', 2]);
    assert.equal(events.filter(e => e[0] === 'Ford').length, fordsBefore + 1);

    // A user pick blocks the default.
    instance.yafcUserPicked = true;
    const after = events.length;
    instance.yafcApplyDefault();
    assert.deepEqual(events.slice(after).filter(e => e[0] === 'PUT' || e[0] === 'Ford'), []);
}

// ---- hide releases the lease with a valid compose=0 record ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: '561.672.783;',
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;
    instance.yafcVisibleChanged(true);
    instance.yafcPanelOpen = true;
    const before = events.length;
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false);
    assert.equal(instance.yafcSession, '');
    assert.equal(instance.yafcPanelOpen, false, 'panel closes on hide');
    const puts = events.slice(before).filter(e => e[0] === 'PUT');
    const release = puts[puts.length - 1];
    assert.match(release[2], /^[^;]+;\d+;0;(\d+,){15}\d+\n$/, 'release record');
    const seqs = events.filter(e => e[0] === 'PUT').map(e => Number(/^[^;]+;(\d+);/.exec(e[2])[1]));
    assert.ok(seqs[seqs.length - 1] > seqs[seqs.length - 2], 'release advances the sequence');
}

// ---- a hidden popup stays released until an explicit show ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: '566.677.788;',
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;
    instance.yafcVisibleChanged(true);
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcHidden, true, 'hide latches the poll');

    // The session file is still there, but the poll must not re-adopt it.
    const before = events.length;
    instance.yafcPoll();
    assert.equal(instance.yafcSession, '', 'poll stays idle while hidden');
    assert.deepEqual(events.slice(before), [], 'no republish while hidden');

    // An explicit show clears the latch and re-takes the layout.
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcHidden, false);
    assert.equal(instance.yafcSession, '566.677.788;');
    assert.ok(events.filter(e => e[0] === 'PUT').length > 0, 'republish after show');

    // A tap is the other resume path: it proves the popup is up.
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcHidden, true);
    instance.yafcSelectView('front');
    assert.equal(instance.yafcHidden, false, 'a tap clears the latch');
}

// ---- a Ford report after a hide does not apply a stale pending view ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
        [sessionPath]: '562.673.784;',
    });
    instance.showFrontCamera = true;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;
    instance.yafcVisibleChanged(true);
    instance.yafcSelectView('front');
    assert.equal(instance.yafcPendingView, 'front');

    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcPendingView, '', 'hide clears the pending key');
    const before = events.length;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 5;
    instance.yafcFordView = 5;
    instance.yafcCommitPendingView();
    assert.deepEqual(events.slice(before).filter(e => e[0] === 'PUT' || e[0] === 'Ford'), []);
    assert.equal(instance.yafcViewKey, 'front360', 'layout not applied from a stale report');
}

// ---- the poll renews the lease without restarting cover or default ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nrear_view=rear\n',
        [sessionPath]: '563.674.785;',
    });
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 2;
    instance.yafcFordView = 2;
    instance.yafcVisibleChanged(true);
    instance.yafcSelectView('zoom'); // cover up, dwell running
    assert.equal(instance.yafcCover, true);
    const before = events.length;
    instance.yafcPoll();
    instance.yafcPoll();
    instance.yafcPoll();
    const after = events.slice(before);
    assert.equal(after.filter(e => e[0] === 'PUT').length, 3, 'one lease renewal per tick');
    assert.deepEqual(after.filter(e => e[0] === 'start'), [], 'no cover/dwell restart from the poll');
}

// ---- a Ford report mismatch keeps the lease on a matching layout ----
{
    const { instance, events } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nrear_view=rear\n',
        [sessionPath]: '565.676.787;',
    });
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 1;
    instance.yafcFordView = 1;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcViewKey, 'rear360');

    const puts = events.filter(e => e[0] === 'PUT').length;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 3; // IPMBRearSplit
    instance.yafcFordView = 3;
    instance.yafcPoll();
    assert.equal(instance.yafcViewKey, 'wide', 'reconciles to the new report');
    assert.equal(events.filter(e => e[0] === 'PUT').length, puts + 1, 'publishes the matching layout');
}

// ---- a session that appears after entry publishes the taken layout ----
{
    const { instance, events, files } = rig(popup, {
        [confPath]: 'mode=compose\nenabled=1\nfront_view=front360\n',
    });
    instance.showFrontCamera = true;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcShown, true, 'layout from camera.conf without a session');
    assert.equal(events.filter(e => e[0] === 'PUT').length, 0, 'no publish without a session');

    files[sessionPath] = '564.675.786;';
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcFordView = 4;
    instance.yafcPoll();
    assert.equal(instance.yafcSession, '564.675.786;');
    assert.equal(events.filter(e => e[0] === 'PUT').length, 1, 'publishes once the session appears');
    assert.equal(instance.yafcRequestedKey, 'front360');
}

// ---- leaving Zoomed View dwells the cover 300 ms longer ----
{
    const { instance } = rig(popup);
    instance.yafcCoverMs = 700;
    instance.yafcZoomSwitch = true;
    instance.yafcCoverDwell();
    assert.equal(instance.yafcCoverTimer.interval, 1000, 'zoom-out extra');
    assert.equal(instance.yafcZoomSwitch, false, 'extra applied once');
}

// ---- failure modes ----

// No ready reply does not hand the layout back to Ford: the session file is the
// liveness proof, and the request is renewed on every poll instead.
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
    const puts = events.filter(e => e[0] === 'PUT').length;
    instance.yafcPoll();
    assert.equal(instance.yafcSession, session, 'session kept when no reply arrives');
    assert.equal(instance.yafcShown, true, 'still composed when no reply arrives');
    assert.equal(events.filter(e => e[0] === 'PUT').length, puts + 1, 'lease renewed without a reply');
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
    // The chrome follows yafcHideChrome, which is a readonly binding on
    // yafcHideChromePref. The rig snapshots readonly values, so assert the pref
    // the binding reads.
    assert.equal(instance.yafcHideChromePref, false, 'chrome returns on DISABLE');
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
    // The next tick adopts the restarted native and re-takes the layout.
    instance.yafcPoll();
    assert.equal(instance.yafcSession, '999.888.777;', 'adopts the restarted session');
    assert.equal(instance.yafcShown, true, 're-takes the layout after a restart');
}

// Mismatched ready: the layout comes from camera.conf and the live session, so a
// stale ready reply no longer returns the popup to stock.
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
    assert.equal(instance.yafcShown, true, 'layout taken from camera.conf despite a stale ready');
    assert.equal(instance.yafcSession, session, 'session persists');

    // Still composed on a later stale ready
    instance.yafcPoll();
    assert.equal(instance.yafcShown, true, 'still composed on a stale ready');
}

// ---- bindings: chrome, height, layout ----

for (const target of ['zoomButton', 'cameraViewButtons', 'pdcImage', 'bottomContainer', 'cancelButton', 'textLabel', 'container']) {
    assert.match(popup, new RegExp(`Binding\\s*\\{\\s*target: ${target}\\b[^}]+when: yafcHideChrome`));
    assert.doesNotMatch(popup, new RegExp(`\\b${target}\\.(?:visible|source|height)\\s*=`));
}
// The chrome hide is config-only, like the working build. Gating it on the
// session handshake left the bars and Ford's own controls on top.
assert.match(popup, /readonly property bool yafcHideChrome: yafcHideChromePref/);
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
