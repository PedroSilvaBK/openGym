/* Apple Watch recordings (recordings.js): a motion file uploaded in chunks that each fit the 5 MB
   /api/ cap, completed by its manifest, listed, downloaded and deleted — each profile seeing only
   its own. Real server.js in a child. */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { boundPort } from './helpers.mjs';

const API = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SECRET = crypto.randomBytes(32).toString('hex');
function mintSession(uid, sv = 0) {
  const payload = `${uid}:${Date.now() + 86400000}:${sv}`;
  return payload + '.' + crypto.createHmac('sha256', SECRET).update(payload).digest('base64url');
}
const A = 'u_rec_a', B = 'u_rec_b';
const bearer = uid => ({ Authorization: `Bearer ${mintSession(uid)}` });
const NAME = 'opengym-20261017-181500';
const manifest = { format: 'opengym-watch-motion', version: 1, start: 1760717700000, session: { name: 'Full Body A' }, events: [{ type: 'setStart', t: 5 }, { type: 'setEnd', t: 11 }, { type: 'setEnd', t: 19 }] };

async function startServer(t, env = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gym-rec-'));
  fs.writeFileSync(path.join(dataDir, 'secret'), SECRET, { mode: 0o600 });
  const users = [A, B].map(id => ({ id, name: id, created: new Date().toISOString() }));
  fs.writeFileSync(path.join(dataDir, 'db.json'), JSON.stringify({ users, creds: [], subs: [], invites: [] }));
  const child = spawn(process.execPath, ['server.js'], {
    cwd: API, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, PORT: '0', DATA_DIR: dataDir, ORIGIN: 'http://localhost:8080', RP_ID: 'localhost', RECORDINGS: '1', RECORDINGS_MIN_FREE_MB: '0', ...env }
  });
  const h = { log: '', dataDir };
  child.stdout.on('data', d => h.log += d);
  child.stderr.on('data', d => h.log += d);
  t.after(() => { child.kill('SIGKILL'); fs.rmSync(dataDir, { recursive: true, force: true }); });
  h.api = `http://127.0.0.1:${await boundPort(child, () => h.log)}`;
  return h;
}

const chunk = (h, uid, offset, bytes, name = NAME) =>
  fetch(`${h.api}/api/recordings/${name}/chunk?offset=${offset}`, { method: 'POST', headers: { ...bearer(uid), 'Content-Type': 'application/octet-stream' }, body: bytes });
const finish = (h, uid, body, name = NAME) =>
  fetch(`${h.api}/api/recordings/${name}/finish`, { method: 'POST', headers: { ...bearer(uid), 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

test('a recording goes up in chunks, resumes, and counts once its manifest matches', async t => {
  const h = await startServer(t);
  const motion = crypto.randomBytes(6 * 1024 * 1024 + 123);   // two chunks
  const [first, second] = [motion.subarray(0, 4 * 1024 * 1024), motion.subarray(4 * 1024 * 1024)];
  const sha256 = crypto.createHash('sha256').update(motion).digest('hex');

  const cfg = await (await fetch(`${h.api}/api/config`)).json();
  assert.equal(cfg.recordings.chunkBytes, 4 * 1024 * 1024, 'the server says it takes recordings');

  assert.equal((await chunk(h, A, 0, first)).status, 200);
  // The same chunk again (an answer lost on the way back): held once, not twice.
  assert.deepEqual(await (await chunk(h, A, 0, first)).json(), { size: first.length });
  // A gap says where to resume.
  const gap = await chunk(h, A, first.length + 10, second);
  assert.equal(gap.status, 409);
  assert.equal((await gap.json()).size, first.length);

  // Finishing early: the server says what it holds.
  const early = await finish(h, A, { manifest, size: motion.length, sha256 });
  assert.equal(early.status, 409);

  assert.deepEqual(await (await chunk(h, A, first.length, second)).json(), { size: motion.length });
  const done = await finish(h, A, { manifest, size: motion.length, sha256 });
  assert.equal(done.status, 200);
  const rec = await done.json();
  assert.equal(rec.name, NAME);
  assert.equal(rec.sets, 2);
  assert.equal(rec.session, 'Full Body A');

  // Listed, downloadable byte for byte, and a repeated finish answers the same recording.
  const list = await (await fetch(`${h.api}/api/recordings`, { headers: bearer(A) })).json();
  assert.deepEqual(list.recordings.map(r => r.name), [NAME]);
  const got = Buffer.from(await (await fetch(`${h.api}/api/recordings/${NAME}?file=motion`, { headers: bearer(A) })).arrayBuffer());
  assert.ok(got.equals(motion));
  const json = await (await fetch(`${h.api}/api/recordings/${NAME}?file=json`, { headers: bearer(A) })).json();
  assert.equal(json.format, 'opengym-watch-motion');
  assert.equal((await finish(h, A, { manifest, size: motion.length, sha256 })).status, 200);
  // Complete is complete: no more chunks for it.
  assert.equal((await chunk(h, A, 0, first)).status, 409);

  // Another profile sees none of it.
  const other = await (await fetch(`${h.api}/api/recordings`, { headers: bearer(B) })).json();
  assert.deepEqual(other.recordings, []);
  assert.equal((await fetch(`${h.api}/api/recordings/${NAME}?file=motion`, { headers: bearer(B) })).status, 404);
  assert.equal((await fetch(`${h.api}/api/recordings/${NAME}`, { method: 'DELETE', headers: bearer(B) })).status, 404);

  // Deleted by its owner.
  assert.equal((await fetch(`${h.api}/api/recordings/${NAME}`, { method: 'DELETE', headers: bearer(A) })).status, 200);
  assert.deepEqual((await (await fetch(`${h.api}/api/recordings`, { headers: bearer(A) })).json()).recordings, []);
});

test('a motion file that does not match its hash is refused and dropped', async t => {
  const h = await startServer(t);
  const motion = crypto.randomBytes(1000);
  await chunk(h, A, 0, motion);
  const r = await finish(h, A, { manifest, size: motion.length, sha256: 'a'.repeat(64) });
  assert.equal(r.status, 422);
  assert.equal((await r.json()).code, 'hash-mismatch');
  // Dropped: the upload starts over from nothing.
  assert.equal((await (await chunk(h, A, 0, motion)).json()).size, motion.length);
});

test('no session, a bad name, an oversized chunk and the quota are refused; without RECORDINGS=1 there is nothing', async t => {
  const h = await startServer(t, { RECORDINGS_QUOTA_MB: '1' });
  assert.equal((await fetch(`${h.api}/api/recordings`)).status, 401);
  assert.equal((await fetch(`${h.api}/api/recordings/${NAME}/chunk?offset=0`, { method: 'POST', body: 'x' })).status, 401);
  assert.equal((await chunk(h, A, 0, Buffer.from('x'), 'not-a-recording')).status, 400);
  assert.equal((await finish(h, A, { manifest: { format: 'other' }, size: 1, sha256: 'a'.repeat(64) })).status, 400);
  const big = await chunk(h, A, 0, crypto.randomBytes(4 * 1024 * 1024 + 1));
  assert.equal(big.status, 413);
  const quota = await chunk(h, A, 0, crypto.randomBytes(1024 * 1024 + 1));
  assert.equal(quota.status, 413);
  assert.equal((await quota.json()).code, 'quota');
  assert.ok(!/^\s+at /m.test(h.log), 'no stack traces in the log');

  const off = await startServer(t, { RECORDINGS: '' });
  assert.equal((await fetch(`${off.api}/api/recordings`, { headers: bearer(A) })).status, 404);
  assert.equal((await (await fetch(`${off.api}/api/config`)).json()).recordings, undefined);
});
