import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

// Run the shipped form code against synthetic DOM controls; no real account,
// network, cookies or Keychain is involved.
const source = readFileSync(new URL('../Sources/GarminDesk/GarminWebSession.swift', import.meta.url), 'utf8');
const script = name => source.match(new RegExp(`private static let ${name} = #"""\\n([\\s\\S]*?)\\n    """#`))[1];
const inspect = new Function(script('loginFormScript'));
const submit = new Function('username', 'password', script('loginSubmitScript'));
let checks = 0;
function check(value, message) { checks++; assert.ok(value, message); }
class Input {
    constructor() { this.hidden = false; this.disabled = false; this.events = []; this.stored = ''; }
    set value(value) { this.stored = value; }
    get value() { throw new Error('The script must not read existing passwords'); }
    getClientRects() { return this.hidden ? [] : [{}]; }
    dispatchEvent(event) { this.events.push(event.type); }
    hasAttribute(name) { return name === 'formaction' && this.formAction !== undefined; }
}
globalThis.HTMLInputElement = Input;
globalThis.getComputedStyle = element => ({display: element.hidden ? 'none' : 'block', visibility: 'visible'});
let username, password, button, form, passwords, verification, clicks;
function reset() {
    clicks = 0;
    globalThis.location = {origin: 'https://sso.garmin.com', href: 'https://sso.garmin.com/portal/sso/embed'};
    globalThis.garminDeskLoginSubmitted = false;
    username = new Input(); password = new Input(); button = new Input();
    button.click = () => clicks++;
    form = {action: '/portal/signin', querySelectorAll: selector => selector.startsWith('button') ? [button] : [username]};
    password.form = form; passwords = [password]; verification = [];
    globalThis.document = {querySelectorAll: selector => selector === 'input[type="password"]' ? passwords : verification};
    inspect();
}
reset();
check(globalThis.garminDeskLoginForm().state === 'form', 'A normal SSO sign-in form is recognized');
const secret = 'synthetic-"-\\-пароль-<script>';
check(submit('fixture@example.test', secret), 'Saved credentials submit once');
check(username.stored === 'fixture@example.test' && password.stored === secret, 'Arguments retain quotes, Unicode and backslashes');
check(clicks === 1 && username.events.join(',') === 'input,change' && password.events.join(',') === 'input,change', 'Native input setters notify the website and invoke its own submit handler');
check(!submit('fixture@example.test', secret) && clicks === 1, 'A failed form cannot resubmit in the same document');
for (const origin of ['https://evil.example', 'https://sso.garmin.com.evil.example', 'http://sso.garmin.com', 'https://sso.garmin.com:8443', 'https://connect.garmin.com']) {
    reset(); location.origin = origin;
    check(!submit('fixture@example.test', secret) && clicks === 0 && password.stored === '', 'Passwords never enter another origin');
}
for (const action of ['https://evil.example/login', '//evil.example/login', 'http://sso.garmin.com/login', 'https://connect.garmin.com/login']) {
    reset(); form.action = action;
    check(!submit('fixture@example.test', secret) && password.stored === '', 'Form action cannot send a password elsewhere');
}
reset(); button.formAction = 'https://evil.example/login';
check(!submit('fixture@example.test', secret) && password.stored === '', 'A button override cannot redirect a saved password');
for (const mode of ['otp', 'captcha', 'reset-password', 'two-passwords', 'hidden-password', 'disabled-submit', 'missing-username', 'no-form']) {
    reset();
    if (['otp', 'captcha'].includes(mode)) verification = [new Input()];
    if (mode === 'reset-password') password.autocomplete = 'new-password';
    if (mode === 'two-passwords') passwords.push(new Input());
    if (mode === 'hidden-password') password.hidden = true;
    if (mode === 'disabled-submit') button.disabled = true;
    if (mode === 'missing-username') username.hidden = true;
    if (mode === 'no-form') password.form = null;
    check(!submit('fixture@example.test', secret) && clicks === 0 && password.stored === '', `No submission for ${mode}`);
}
reset(); verification = [new Input()]; verification[0].hidden = true;
check(submit('fixture@example.test', secret), 'An inactive hidden verification control does not block the real login form');
console.log(`WebLoginScriptTests: ${checks} checks passed`);
