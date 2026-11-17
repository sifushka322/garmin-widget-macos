import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

// Run the shipped form code against synthetic DOM controls; no real account,
// network, cookies or Keychain is involved.
const source = readFileSync(new URL('../Sources/GarminDesk/GarminWebSession.swift', import.meta.url), 'utf8');
const script = name => source.match(new RegExp(`private static let ${name} = #"""\\n([\\s\\S]*?)\\n    """#`))[1];
const inspect = new Function(script('loginFormScript'));
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const runSubmit = new AsyncFunction('username', 'password', 'submissionID', script('loginSubmitScript'));
let lastObservation;
const submit = async (username, password) => {
    lastObservation = await runSubmit(username, password, 'fixture-submission');
    return lastObservation.clicked;
};
const originalTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
const originalMessageChannel = globalThis.MessageChannel;
const originalNow = Date.now;
let fakeTime = 0, observations = [], extraButtons = [];
let waits = 0, onWait, onBlur, activeInput, interactionSequence = [], timersSuspended = false, timerID = 0;
const timers = new Map(), observers = new Set();
const eventTarget = new EventTarget();
Date.now = () => fakeTime;
globalThis.addEventListener = eventTarget.addEventListener.bind(eventTarget);
globalThis.removeEventListener = eventTarget.removeEventListener.bind(eventTarget);
globalThis.dispatchEvent = eventTarget.dispatchEvent.bind(eventTarget);
globalThis.webkit = {messageHandlers:{garminLoginForm:{postMessage: value => observations.push(value)}}};
globalThis.setTimeout = (callback, delay) => {
    const id = ++timerID;
    timers.set(id, {callback, deadline:fakeTime + delay});
    return id;
};
globalThis.clearTimeout = id => timers.delete(id);
globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; }
    observe() { observers.add(this); }
    disconnect() { observers.delete(this); }
};
// Synthetic page-render/mutation turns are independent of setTimeout. This
// exercises the important case where validation changes while timers stall.
function pageTurn(callback) {
    queueMicrotask(() => {
        waits++; fakeTime += 100; onWait?.(); callback();
        if (!observers.size) return;
        if (onWait && waits < 5) {
            pageTurn(() => { for (const observer of [...observers]) observer.callback([]); });
        } else if (!timersSuspended) {
            for (const [id, timer] of [...timers]) {
                if (!timers.has(id)) continue;
                fakeTime = Math.max(fakeTime, timer.deadline);
                timers.delete(id); timer.callback();
            }
        }
    });
}
globalThis.MessageChannel = class {
    constructor() {
        this.port1 = {onmessage:null, close() { this.closed = true; }};
        this.port2 = {close() { this.closed = true; }, postMessage: () => {
            pageTurn(() => { if (!this.port1.closed) this.port1.onmessage?.(); });
        }};
    }
};
let checks = 0;
function check(value, message) { checks++; assert.ok(value, message); }
class Input {
    constructor() { this.hidden = false; this.disabled = false; this.events = []; this.stored = ''; }
    set value(value) { this.stored = value; this.wasFilled = true; }
    get value() {
        if (!this.wasFilled) throw new Error('The script must not inspect existing credentials before autofill');
        return this.stored;
    }
    getClientRects() { return this.hidden ? [] : [{}]; }
    focus() {
        if (activeInput && activeInput !== this) activeInput.blur();
        activeInput = this;
        interactionSequence.push(this.role + '.focus');
    }
    blur() {
        if (activeInput !== this) return;
        activeInput = undefined;
        interactionSequence.push(this.role + '.blur');
        onBlur?.(this);
    }
    dispatchEvent(event) { this.events.push(event.type); interactionSequence.push(this.role + '.' + event.type); }
    hasAttribute(name) { return name === 'formaction' && this.formAction !== undefined; }
    getAttribute(name) { return name === 'aria-disabled' ? this.ariaDisabled ?? null : null; }
}
globalThis.HTMLInputElement = Input;
globalThis.getComputedStyle = element => ({display: element.hidden ? 'none' : 'block', visibility: 'visible'});
let username, password, button, form, passwords, verification, clicks;
function reset() {
    clicks = 0; waits = 0; onWait = undefined; onBlur = undefined; activeInput = undefined; interactionSequence = []; fakeTime = 0; observations = []; extraButtons = []; lastObservation = undefined; timersSuspended = false;
    assert.equal(observers.size, 0, 'Every completed submission disconnects its mutation observer');
    assert.equal(timers.size, 0, 'Every completed submission releases its deadline timer');
    globalThis.location = {origin: 'https://sso.garmin.com', href: 'https://sso.garmin.com/portal/sso/embed'};
    globalThis.garminDeskLoginSubmitted = false;
    globalThis.garminDeskCancelledLogins = new Set();
    username = new Input(); password = new Input(); button = new Input();
    username.role = 'username'; password.role = 'password';
    button.click = () => clicks++;
    form = {action: '/portal/signin', querySelectorAll: selector => selector.startsWith('button') ? [button, ...extraButtons] : [username]};
    password.form = form; passwords = [password]; verification = [];
    globalThis.document = {querySelectorAll: selector => selector === 'input[type="password"]' ? passwords : verification};
    inspect();
}
reset();
check(globalThis.garminDeskLoginForm().state === 'form', 'A normal SSO sign-in form is recognized');
const secret = 'synthetic-"-\\-пароль-<script>';
check(await submit('fixture@example.test', secret), 'Saved credentials submit once');
check(username.stored === 'fixture@example.test' && password.stored === secret, 'Arguments retain quotes, Unicode and backslashes');
check(clicks === 1 && username.events.join(',') === 'input,change' && password.events.join(',') === 'input,change', 'Native input setters notify the website and invoke its own submit handler');
check(interactionSequence.join(',') === 'username.focus,username.input,username.change,username.blur,password.focus,password.input,password.change,password.blur',
      'Normal focus, input/change and blur follow field order so Garmin can validate touched fields');
check(!await submit('fixture@example.test', secret) && clicks === 1, 'A failed form cannot resubmit in the same document');
for (const origin of ['https://evil.example', 'https://sso.garmin.com.evil.example', 'http://sso.garmin.com', 'https://sso.garmin.com:8443', 'https://connect.garmin.com']) {
    reset(); location.origin = origin;
    check(!await submit('fixture@example.test', secret) && clicks === 0 && password.stored === '', 'Passwords never enter another origin');
}
for (const action of ['https://evil.example/login', '//evil.example/login', 'http://sso.garmin.com/login', 'https://connect.garmin.com/login']) {
    reset(); form.action = action;
    check(!await submit('fixture@example.test', secret) && password.stored === '', 'Form action cannot send a password elsewhere');
}
reset(); button.formAction = 'https://evil.example/login';
check(!await submit('fixture@example.test', secret) && password.stored === '', 'A button override cannot redirect a saved password');
for (const mode of ['otp', 'captcha', 'reset-password', 'two-passwords', 'hidden-password', 'disabled-password', 'readonly-password', 'disabled-username', 'readonly-username', 'missing-username', 'no-form']) {
    reset();
    if (['otp', 'captcha'].includes(mode)) verification = [new Input()];
    if (mode === 'reset-password') password.autocomplete = 'new-password';
    if (mode === 'two-passwords') passwords.push(new Input());
    if (mode === 'hidden-password') password.hidden = true;
    if (mode === 'disabled-password') password.disabled = true;
    if (mode === 'readonly-password') password.readOnly = true;
    if (mode === 'disabled-username') username.disabled = true;
    if (mode === 'readonly-username') username.readOnly = true;
    if (mode === 'missing-username') username.hidden = true;
    if (mode === 'no-form') password.form = null;
    check(!await submit('fixture@example.test', secret) && clicks === 0 && password.stored === '', `No submission for ${mode}`);
}
reset(); verification = [new Input()]; verification[0].hidden = true;
check(await submit('fixture@example.test', secret), 'An inactive hidden verification control does not block the real login form');
// Garmin keeps Sign In disabled until the filled inputs pass its own validation.
reset(); button.disabled = true;
check(globalThis.garminDeskLoginForm().state === 'form', 'A visible initially disabled submit still identifies the normal login form');
onWait = () => { if (waits === 3) button.disabled = false; };
check(await submit('fixture@example.test', secret), 'Autofill waits for asynchronous page validation');
check(waits === 3 && clicks === 1 && username.stored === 'fixture@example.test' && password.stored === secret,
      'Fields are filled once and the page enables its own button before the only click');
check(!await submit('fixture@example.test', secret) && clicks === 1, 'A validated form still cannot submit twice');
reset(); button.disabled = true;
check(!await submit('fixture@example.test', secret) && waits === 1 && clicks === 0 && button.disabled,
      'Validation timeout leaves a blocked button untouched and never submits');
check(!await submit('fixture@example.test', secret) && waits === 1, 'A failed validation cannot start another autofill loop');
reset(); button.ariaDisabled = 'true';
onWait = () => { button.ariaDisabled = 'false'; };
check(await submit('fixture@example.test', secret) && waits === 1 && clicks === 1, 'ARIA-disabled controls also wait for site validation');
for (const change of ['mfa', 'origin', 'form-action', 'button-action', 'hidden-submit', 'disabled-input', 'new-form', 'new-input', 'values-changed', 'ambiguous-submit', 'cancelled']) {
    reset(); button.disabled = true;
    onWait = () => {
        button.disabled = false;
        if (change === 'mfa') verification = [new Input()];
        if (change === 'origin') location.origin = 'https://evil.example';
        if (change === 'form-action') form.action = 'https://evil.example/login';
        if (change === 'button-action') button.formAction = 'https://evil.example/login';
        if (change === 'hidden-submit') button.hidden = true;
        if (change === 'disabled-input') username.disabled = true;
        if (change === 'new-form') password.form = {...form};
        if (change === 'new-input') username = new Input();
        if (change === 'values-changed') password.stored = 'changed-by-page';
        if (change === 'ambiguous-submit') extraButtons = [new Input()];
        if (change === 'cancelled') globalThis.garminDeskCancelledLogins.add('fixture-submission');
    };
    check(!await submit('fixture@example.test', secret) && clicks === 0 && waits === 1,
          `No delayed submission after ${change}`);
}
reset(); globalThis.garminDeskCancelledLogins.add('fixture-submission');
check(!await submit('fixture@example.test', secret) && password.stored === '' && clicks === 0,
      'Cancellation delivered before script execution prevents filling credentials');
reset(); button.disabled = true;
onWait = () => { button.disabled = false; };
const first = submit('fixture@example.test', secret);
check(!await submit('fixture@example.test', secret), 'A simultaneous second callback cannot fill or submit again');
check(await first && clicks === 1, 'The original validation flow alone submits');
// The first click waits until a queued page-render task completes, even if the
// button initially appears enabled. Re-rendering just that button is compatible.
reset();
let rendered = false;
onWait = () => {
    rendered = true;
    button = new Input();
    button.click = () => { assert.ok(rendered); clicks++; };
};
check(await submit('fixture@example.test', secret) && clicks === 1 && waits === 1,
      'A queued React render may replace only the trusted submit before the one click');
check(lastObservation.outcome === 'submitted' && lastObservation.filledFields === 2 &&
      lastObservation.validationWaits === 1 && lastObservation.clicked,
      'Non-sensitive completion metadata distinguishes filled fields and actual click attempt');
check(observations.some(value => value.outcome === 'filled') && observations.some(value => value.outcome === 'submitted'),
      'Progress reaches native diagnostics even when navigation discards the final JavaScript result');
check(!JSON.stringify(observations).includes(secret) && !JSON.stringify(observations).includes('fixture@example.test'),
      'Login diagnostics never export credential values');
reset(); button.disabled = true;
onWait = () => { button = new Input(); button.formAction = 'https://evil.example/login'; button.click = () => clicks++; };
check(!await submit('fixture@example.test', secret) && clicks === 0, 'A replacement button still needs its action validated');
reset(); button.disabled = true;
onWait = () => { fakeTime += 6000; button.disabled = false; };
check(!await submit('fixture@example.test', secret) && lastObservation.outcome === 'validation_timeout' && clicks === 0,
      'Offscreen timer delays cannot cause a late password submission beyond the validation deadline');
reset(); button.disabled = true;
onBlur = element => {
    if (element === password && username.stored === 'fixture@example.test' && password.stored === secret) button.disabled = false;
};
check(await submit('fixture@example.test', secret) && clicks === 1,
      'A form that validates only when password loses focus completes through normal blur');
reset(); button.disabled = true; timersSuspended = true;
onWait = () => { if (waits === 3) button.disabled = false; };
check(await submit('fixture@example.test', secret) && clicks === 1 && waits === 3,
      'Mutation-driven validation submits even when every page timer is suspended');
reset(); button.disabled = true; timersSuspended = true;
onWait = () => {
    if (waits === 2) {
        globalThis.garminDeskCancelledLogins.add('fixture-submission');
        globalThis.dispatchEvent(new Event('garminDeskLoginCancelled'));
    }
};
check(!await submit('fixture@example.test', secret) && lastObservation.outcome === 'cancelled' && clicks === 0,
      'Native cancellation resolves a pending observer without waiting for any page timer');
check(observers.size === 0 && timers.size === 0, 'Submission completion releases observers and timeout resources');
globalThis.setTimeout = originalTimeout;
globalThis.clearTimeout = originalClearTimeout;
globalThis.MessageChannel = originalMessageChannel;
delete globalThis.MutationObserver;
delete globalThis.addEventListener;
delete globalThis.removeEventListener;
delete globalThis.dispatchEvent;
Date.now = originalNow;
delete globalThis.webkit;
console.log(`WebLoginScriptTests: ${checks} checks passed`);
