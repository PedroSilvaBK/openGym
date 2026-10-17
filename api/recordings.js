// Training data from the Apple Watch (frontend/ios/App/Watch/SensorRecorder.swift, ml/README.md):
// a workout's motion at 100 Hz (`<name>.motion`) and its manifest of labels (`<name>.json`),
// uploaded by the paired phone and kept per profile under DATA_DIR/recordings/<uid>/.
//
// The motion arrives in chunks of at most CHUNK_BYTES, appended in order: every request stays
// under the 5 MB the web container allows on /api/ (web/nginx.conf.template), so no proxy needs a
// bigger cap, and an upload cut off halfway resumes from what the server already has instead of
// starting over. The manifest comes last, with the size and sha256 of the whole motion file; only
// then does the recording count. Off unless the instance sets RECORDINGS=1: an instance that does
// not collect training data answers exactly as it did before (/api/config included).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

// What SensorRecorder names its files: opengym-YYYYMMDD-HHMMSS.
export const NAME_RE = /^opengym-\d{8}-\d{6}$/;
export const CHUNK_BYTES = 4 * 1024 * 1024;
const MB = 1024 * 1024;

export class RecordingError extends Error {
  constructor(status, code, extra = {}) { super(code); this.status = status; this.code = code; this.extra = extra; }
}

export function recordingLimits(env = process.env) {
  const num = (k, d, min) => {
    const v = Number(env[k]);
    return Number.isFinite(v) && v >= min ? v : d;
  };
  return {
    enabled: env.RECORDINGS === '1',
    quotaMB: num('RECORDINGS_QUOTA_MB', 4096, 0),     // per profile; 0 = no cap
    maxMB: num('RECORDINGS_MAX_MB', 200, 1),           // one recording (~10 hours at 20 MB/h)
    minFreeMB: num('RECORDINGS_MIN_FREE_MB', 512, 0),  // refuse below this much free disk
  };
}

// The request body as bytes, refused past `max` (a 413 the caller answers).
export function readChunk(req, max = CHUNK_BYTES) {
  return new Promise((resolve, reject) => {
    let size = 0, over = false;
    const chunks = [];
    req.on('data', d => {
      size += d.length;
      if (over) { if (size > 2 * max) req.destroy(); return; }
      if (size > max) { over = true; chunks.length = 0; reject(new RecordingError(413, 'chunk-too-large', { max })); return; }
      chunks.push(d);
    });
    req.on('end', () => { if (!over) resolve(Buffer.concat(chunks)); });
    req.on('error', reject);
  });
}

export function createRecordingStore({ dir, limits }) {
  const userDir = uid => path.join(dir, uid);
  const tmpDir = uid => path.join(userDir(uid), '.partial');
  const sizeOf = p => { try { return fs.statSync(p).size; } catch { return 0; } };
  const checkName = name => { if (!NAME_RE.test(name || '')) throw new RecordingError(400, 'bad-name'); };

  function freeBytes(p) {
    try { const s = fs.statfsSync(p); return Number(s.bavail) * Number(s.bsize); } catch { return Infinity; }
  }

  function usedBytes(uid) {
    let n = 0;
    for (const d of [userDir(uid), tmpDir(uid)]) {
      let names = [];
      try { names = fs.readdirSync(d); } catch { continue; }
      for (const f of names) n += sizeOf(path.join(d, f));
    }
    return n;
  }

  // Appends one chunk at `offset`. The answer is always how much the server holds, so a client
  // that lost an answer (or the connection) asks again from there: a chunk it already sent comes
  // back as the same size, never appended twice, and a gap is a 409 that says where to resume.
  function append(uid, name, offset, bytes) {
    checkName(name);
    if (!Number.isSafeInteger(offset) || offset < 0) throw new RecordingError(400, 'bad-offset');
    if (fs.existsSync(path.join(userDir(uid), name + '.json'))) throw new RecordingError(409, 'exists');
    const tmp = path.join(tmpDir(uid), name + '.motion');
    const have = sizeOf(tmp);
    if (offset + bytes.length <= have) return { size: have };
    if (offset !== have) throw new RecordingError(409, 'offset', { size: have });
    if (have + bytes.length > limits.maxMB * MB) throw new RecordingError(413, 'too-large', { maxMB: limits.maxMB });
    if (limits.quotaMB > 0 && usedBytes(uid) + bytes.length > limits.quotaMB * MB) {
      throw new RecordingError(413, 'quota', { quotaMB: limits.quotaMB });
    }
    fs.mkdirSync(tmpDir(uid), { recursive: true });
    if (limits.minFreeMB > 0 && freeBytes(tmpDir(uid)) - bytes.length < limits.minFreeMB * MB) {
      throw new RecordingError(507, 'disk-full');
    }
    fs.appendFileSync(tmp, bytes);
    return { size: have + bytes.length };
  }

  // The motion file is complete: its size and hash must match what the phone sent. The manifest
  // is the watch's own JSON, kept as it came (it is small and only ever read back as data).
  function finish(uid, name, { manifest, size, sha256 } = {}) {
    checkName(name);
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest) || manifest.format !== 'opengym-watch-motion') {
      throw new RecordingError(400, 'bad-manifest');
    }
    const text = JSON.stringify(manifest);
    if (text.length > 2 * MB) throw new RecordingError(413, 'manifest-too-large');
    const final = path.join(userDir(uid), name + '.json');
    if (fs.existsSync(final)) return entry(uid, name);   // a repeated finish: already done
    const tmp = path.join(tmpDir(uid), name + '.motion');
    const have = sizeOf(tmp);
    if (!fs.existsSync(tmp) || have !== size) throw new RecordingError(409, 'incomplete', { size: have });
    const hash = crypto.createHash('sha256').update(fs.readFileSync(tmp)).digest('hex');
    if (hash !== String(sha256 || '').toLowerCase()) {
      fs.rmSync(tmp, { force: true });
      throw new RecordingError(422, 'hash-mismatch');
    }
    fs.renameSync(tmp, path.join(userDir(uid), name + '.motion'));
    // The manifest last: its presence is what makes the recording count (list, exists).
    const part = final + '.part';
    fs.writeFileSync(part, text);
    fs.renameSync(part, final);
    return entry(uid, name);
  }

  function entry(uid, name) {
    const json = path.join(userDir(uid), name + '.json');
    let m = {};
    try { m = JSON.parse(fs.readFileSync(json, 'utf8')); } catch { /* listed by its files alone */ }
    const events = Array.isArray(m.events) ? m.events : [];
    return {
      name,
      bytes: sizeOf(path.join(userDir(uid), name + '.motion')) + sizeOf(json),
      start: Number(m.start) || null,
      end: Number(m.end) || null,
      sets: events.filter(e => e && e.type === 'setEnd').length,
      session: typeof m.session?.name === 'string' ? m.session.name : '',
    };
  }

  function list(uid) {
    let names = [];
    try { names = fs.readdirSync(userDir(uid)); } catch { return []; }
    return names.filter(f => f.endsWith('.json')).map(f => f.slice(0, -5)).filter(n => NAME_RE.test(n)).sort().map(n => entry(uid, n));
  }

  function file(uid, name, kind) {
    checkName(name);
    if (kind !== 'motion' && kind !== 'json') throw new RecordingError(400, 'bad-file');
    const p = path.join(userDir(uid), `${name}.${kind}`);
    return fs.existsSync(path.join(userDir(uid), name + '.json')) && fs.existsSync(p) ? p : null;
  }

  function remove(uid, name) {
    checkName(name);
    let removed = false;
    for (const p of [path.join(userDir(uid), name + '.json'), path.join(userDir(uid), name + '.motion'), path.join(tmpDir(uid), name + '.motion')]) {
      if (fs.existsSync(p)) { fs.rmSync(p, { force: true }); removed = true; }
    }
    return removed;
  }

  function removeUser(uid) { fs.rmSync(userDir(uid), { recursive: true, force: true }); }

  // Uploads abandoned halfway (a phone that never came back) after a day.
  function cleanPartial(maxAgeMs = 86400000, now = Date.now()) {
    let removed = 0, uids = [];
    try { uids = fs.readdirSync(dir); } catch { return 0; }
    for (const uid of uids) {
      let names = [];
      try { names = fs.readdirSync(tmpDir(uid)); } catch { continue; }
      for (const f of names) {
        const p = path.join(tmpDir(uid), f);
        try { if (now - fs.statSync(p).mtimeMs > maxAgeMs) { fs.rmSync(p, { force: true }); removed++; } } catch { /* gone */ }
      }
    }
    return removed;
  }

  return { append, finish, list, file, remove, removeUser, cleanPartial, usedBytes };
}
