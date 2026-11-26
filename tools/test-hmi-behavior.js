// Exercise the JavaScript from installer-patched QML without Ford's Qt types.
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
    for (const [, name, expr] of source.matchAll(/^    property \w+ (yafc\w+): (.+)$/gm))
        instance[name] = vm.runInContext(expr, instance);
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
    const denied = rig(popup, { [confPath]: 'mode=compose\n' }, status);
    denied.instance.yafcVisibleChanged(true);
    assert.equal(denied.instance.yafcShown, false);
    assert.deepEqual(denied.events.map(event => event[0]), ['PUT']);
}

const fronts = { front: ['front', 5], front360: ['front360', 4], '360': ['front360only', 4], frontwide: ['frontwide', 6] };
const rears = { rear: ['rear', 2], rear360: ['rear360', 1], '360': ['full360', 1], rearwide: ['wide', 3] };
for (const [pref, [key, ford]] of Object.entries({ ...fronts, invalid: fronts.front360 })) {
    const config = `mode=compose\nenabled=1\nfront_view=${pref}\n`;
    const { instance, events, files } = rig(popup, { [confPath]: config });
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcShown, true);
    assert.equal(instance.yafcViewKey, key);
    assert.deepEqual(events.map(e => e[0]), ['PUT', 'start']);
    assert.equal(events[0][1], viewPath);
    assert.match(events[0][2], /^1;\d+(,\d+){15}\n$/);
    instance.yafcApplyDefault(true, true);
    assert.deepEqual(events.at(-1), ['Ford', ford]);
    instance.yafcVisibleChanged(false);
    assert.equal(instance.yafcShown, false);
    assert.equal(instance.yafcPanelOpen, false);
    assert.equal(files[confPath], config);
    files[disablePath] = '';
    const before = events.length;
    instance.yafcVisibleChanged(true);
    assert.equal(events.length, before);
}
for (const [pref, [key, ford]] of Object.entries(rears)) {
    const { instance, events } = rig(popup, { [confPath]: `mode=compose\nrear_view=${pref}\n` });
    instance.showFrontCamera = false;
    instance.AL2HMIBridge.rvcSource.multicameraShowing = 4;
    instance.yafcVisibleChanged(true);
    assert.equal(instance.yafcViewKey, key);
    instance.yafcApplyDefault(false, true);
    assert.deepEqual(events.at(-1), ['Ford', ford]);
}

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
