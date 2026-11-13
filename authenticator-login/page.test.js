const {test, beforeEach} = require('node:test');
const assert = require('node:assert/strict');
const page = require('./page');
const config = {origin: 'https://dash.cloudflare.com', path: '/two-factor', email: 'person@example.com'};
let field, button, clicks;

class Element extends EventTarget {
    constructor() { super(); this.isConnected = true; this.disabled = false; }
    getClientRects() { return this.isConnected ? [{}] : []; }
}
class Input extends Element {
    constructor() {
        super(); this.type = 'text'; this._value = ''; this.labels = [{innerText: 'Verification code'}];
    }
    get value() { return this._value; }
    set value(value) { this._value = value; }
    checkValidity() { return true; }
}
beforeEach(() => {
    if (global.window?.__macToolingAuthenticator) window.__macToolingAuthenticator.cleanup();
    clicks = 0;
    global.HTMLInputElement = Input;
    global.getComputedStyle = () => ({visibility: 'visible'});
    global.location = {origin: config.origin, pathname: config.path, href: config.origin + config.path};
    global.window = new EventTarget();
    field = new Input();
    button = new Element(); button.innerText = 'Verify'; button.click = () => clicks++;
    global.document = Object.assign(new EventTarget(), {
        activeElement: field, body: {innerText: 'Verify with your authenticator app person@example.com'},
        querySelectorAll: () => [button], hasFocus: () => true
    });
});
function prepare() { assert.equal(page('prepare', config, 'session').ok, true); }
function submit() { return page('submit', config, 'session', '012345'); }
function denied() { assert.equal(submit().ok, false); assert.equal(clicks, 0); assert.equal(field.value, ''); }

test('fills leading-zero code, dispatches input/change and submits once', () => {
    let events = [];
    field.addEventListener('input', () => events.push('input'));
    field.addEventListener('change', () => events.push('change'));
    prepare(); assert.equal(submit().ok, true);
    assert.equal(field.value, '012345'); assert.equal(clicks, 1);
    assert.deepEqual(events, ['input', 'change']);
    assert.equal(submit().ok, false); assert.equal(clicks, 1);
});
test('rejects lookalike host', () => { location.origin += '.example.net'; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects wrong route', () => { location.pathname = '/profile'; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects wrong account', () => { document.body.innerText = 'Verify with your authenticator app other@example.com'; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects email substring match', () => { document.body.innerText = 'Verify with your authenticator app notperson@example.com'; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects non-code input', () => { field.labels = []; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects ambiguous Verify buttons', () => { document.querySelectorAll = () => [button, button]; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects prefilled field', () => { field.value = '123'; assert.equal(page('prepare', config, 'session').ok, false); });
test('rejects changed URL', () => { prepare(); location.href += '?changed'; denied(); });
test('rejects changed account', () => { prepare(); document.body.innerText = 'other@example.com'; denied(); });
test('rejects focus change even after focus returns', () => { prepare(); field.dispatchEvent(new Event('blur')); denied(); });
test('rejects tab/window switch even after returning', () => { prepare(); window.dispatchEvent(new Event('blur')); denied(); });
test('rejects hidden tab', () => { prepare(); document.dispatchEvent(new Event('visibilitychange')); denied(); });
test('rejects replaced field', () => { prepare(); field.isConnected = false; denied(); });
test('rejects expired capture', () => { prepare(); window.__macToolingAuthenticator.started -= 61000; denied(); });
test('rejects stale session nonce', () => {
    prepare(); assert.equal(page('submit', config, 'old', '012345').ok, false); assert.equal(clicks, 0);
    window.__macToolingAuthenticator.cleanup();
});
test('rejects invalid code', () => { prepare(); assert.equal(page('submit', config, 'session', '12345').ok, false); assert.equal(clicks, 0); });
test('does not click a disabled button after filling', () => { prepare(); button.disabled = true; assert.equal(submit().ok, false); assert.equal(clicks, 0); });
test('check detects cancellation before capture finishes', () => {
    prepare(); assert.equal(page('check', config, 'session').ok, true);
    field.dispatchEvent(new Event('input')); assert.equal(page('check', config, 'session').ok, false);
});
