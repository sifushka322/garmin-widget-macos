import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

// Exercise the exact script compiled into the app with synthetic HTTP streams.
// No browser, account, cookie store or real network request is used.
const source = readFileSync(new URL('../Sources/GarminDesk/GarminWebSession.swift', import.meta.url), 'utf8');
const script = source.match(/private static let readScript = #"""\n([\s\S]*?)\n    """#/)[1];
const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
const read = new AsyncFunction('path', 'fetchID', script);
const allowedPath = '/gc-api/userprofile-service/socialProfile';
let count = 0;
let fetchCalls = 0;
let lastSignal;
globalThis.location = {origin:'https://connect.garmin.com'};
globalThis.document = {querySelector: selector => selector === 'meta[name="csrf-token"]' ? {getAttribute: () => 'synthetic-csrf-for-test'} : null};

function response({status=200, body='{"totalSteps":0}', type='application/json', extraHeaders={}, redirected=false, url='https://connect.garmin.com/gc-api/data'}={}) {
    const bytes = new TextEncoder().encode(body);
    return {status, redirected, url, headers:new Headers({'content-type':type,...extraHeaders}),
        body:new ReadableStream({start(controller) { controller.enqueue(bytes); controller.close(); }})};
}
function mockFetch(result) {
    fetchCalls = 0;
    globalThis.fetch = async (url, options) => {
        fetchCalls++;
        assert.equal(new URL(url).origin, 'https://connect.garmin.com');
        assert.equal(options.method, 'GET');
        assert.equal(options.credentials, 'same-origin');
        assert.equal(options.cache, 'no-store');
        assert.equal(options.headers.Authorization, undefined);
        assert.equal(options.headers.Cookie, undefined);
        assert.equal(options.headers['connect-csrf-token'], 'synthetic-csrf-for-test');
        lastSignal = options.signal;
        return result;
    };
}
function check(condition, description) { count++; assert.ok(condition, description); }
async function run(result, path=allowedPath) {
    mockFetch(result);
    try { return await read(path,'test-operation'); }
    finally { check(!globalThis.garminDeskRequests?.['test-operation'], 'operation must release its abort handle'); }
}

let value = await run(response());
check(value.body.totalSteps === 0, 'valid zero is retained');
check(value.status === 200 && value.kind === 'json', 'valid JSON is described correctly');
check(value.jsonValid === true, 'successful parsing is explicit');
check(!JSON.stringify(value).includes('synthetic-csrf-for-test'), 'CSRF value never crosses the native result boundary');
check(lastSignal.aborted, 'completed request releases stream resources');

value = await run(response({status:429, body:'{"error":{"status-code":429}}',extraHeaders:{'retry-after':'1800','cf-mitigated':'challenge'}}));
check(value.status === 429 && value.body.error['status-code'] === 429, 'HTTP and JSON rate limits survive unchanged');
check(value.retryAfter === '1800' && value.challenge === true, 'server wait and challenge metadata survive');
check(fetchCalls === 1, 'transport does not retry a rate limit');

value = await run(response({status:403,body:'<html>PRIVATE CONTENT</html>',type:'text/html',extraHeaders:{'cf-mitigated':'challenge'}}));
check(value.body === null && value.kind === 'html', 'HTML content is not returned to native code');
check(value.challenge && value.status === 403, 'challenge is not disguised as missing metrics');

value = await run(response({status:200,body:'<html>Sign in</html>',type:'text/html',redirected:true,url:'https://sso.garmin.com/portal/sign-in'}));
check(value.signInRedirect, 'normal login redirect is identified');
value = await run(response({body:'invalid json'}));
check(value.body === null && value.jsonValid === false, 'malformed JSON is distinct from valid absence');
value = await run(response({body:'null'}));
check(value.body === null && value.jsonValid === true, 'valid JSON null remains legitimate absence');
value = await run(response({status:204,body:'',type:''}));
check(value.body === null && value.status === 204 && value.jsonValid === false, 'no-content is not fabricated JSON');

const completedStream = response();
await run(completedStream);
check(!completedStream.body.locked, 'completed stream reader releases its lock');
const failedStream = response();
failedStream.body = new ReadableStream({start(controller) { controller.error(new Error('stream failed')); }});
await assert.rejects(run(failedStream), /stream failed/); count++;
check(!failedStream.body.locked && lastSignal.aborted, 'failed stream releases its lock and abort controller');

let cancelledReader = false;
const oversizedStream = response();
oversizedStream.body = new ReadableStream({start(controller) { controller.enqueue(new Uint8Array(4000001)); }, cancel() { cancelledReader = true; }});
await assert.rejects(run(oversizedStream), /too large/); count++;
check(cancelledReader && !oversizedStream.body.locked, 'oversized open stream is cancelled and unlocked');

await assert.rejects(run(response({extraHeaders:{'content-length':'4000001'}})), /too large/); count++;
check(lastSignal.aborted, 'oversized declared body is cancelled');
await assert.rejects(run(response({body:'a'.repeat(4000001)})), /too large/); count++;
check(lastSignal.aborted, 'oversized streamed body is cancelled');

for (const path of ['https://example.com/private','//example.com/private','/gc-api/../private','/app/home']) {
    await assert.rejects(run(response(),path), /Invalid source/); count++;
    check(fetchCalls === 0, 'invalid destinations must be rejected before fetching');
}
globalThis.location = {origin:'https://sso.garmin.com'};
await assert.rejects(run(response()), /Invalid source/); count++;
check(fetchCalls === 0, 'API script cannot run on the sign-in origin');
globalThis.location = {origin:'https://connect.garmin.com'};

let signal;
globalThis.fetch = async (_, options) => {
    signal = options.signal;
    return new Promise((resolve,reject) => signal.addEventListener('abort',() => reject(new Error('aborted')),{once:true}));
};
const pending = read(allowedPath,'cancel-test');
globalThis.garminDeskRequests['cancel-test'].abort();
await assert.rejects(pending,/aborted/); count++;
check(signal.aborted && !globalThis.garminDeskRequests['cancel-test'], 'cancellation releases operation state');

// Probe only document structure. It must not read credentials or send a request.
const readinessSource = source.match(/private static let navigationReadinessScript = #"""\n([\s\S]*?)\n    """#/)[1];
const readiness = new AsyncFunction(readinessSource);
const formElement = ({hidden=false, disabled=false}={}) => ({
    disabled, hidden, get value() { throw new Error('Credentials must not be inspected'); },
    getClientRects: () => hidden ? [] : [{}]
});
let controls = [];
let csrf = undefined;
globalThis.document = {
    querySelectorAll: () => controls,
    querySelector: () => csrf === undefined ? null : {getAttribute: () => csrf},
    get cookie() { throw new Error('Cookies must not be inspected'); }
};
globalThis.getComputedStyle = element => ({display: element.hidden ? 'none' : 'block', visibility: 'visible'});
globalThis.fetch = () => { throw new Error('The readiness probe must not make requests'); };
check(JSON.stringify(await readiness()) === '{"visibleSignIn":false,"connectReady":false}', 'SSO redirect document remains pending');
controls = [formElement({hidden:true}), formElement({disabled:true})];
check(!(await readiness()).visibleSignIn, 'hidden and disabled authentication controls are ignored');
controls = [formElement()];
check((await readiness()).visibleSignIn, 'visible sign-in form is reported only as a boolean');
controls = [];
csrf = 'synthetic-private-csrf';
value = await readiness();
check(value.connectReady && !value.visibleSignIn, 'Connect metadata signals API readiness');
check(!JSON.stringify(value).includes(csrf), 'readiness does not export CSRF metadata');
for (const invalid of ['', 'a'.repeat(4097), 'unsafe\r\nvalue']) {
    csrf = invalid;
    check(!(await readiness()).connectReady, 'invalid metadata cannot mark Connect ready');
}
console.log(`WebReadScriptTests: ${count} checks passed`);
