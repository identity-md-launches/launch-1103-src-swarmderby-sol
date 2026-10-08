// Test-only house key, derived from a fixed seed. test/HouseKey.sol holds its modulus and
// private exponent (printed by this script), and the e2e set-up uses it. It signs like the
// house service: RSASSA-PKCS1-v1_5, SHA-256.
//   node test/fixtures/house-test-key.mjs modulus
//   node test/fixtures/house-test-key.mjs exponent
//   node test/fixtures/house-test-key.mjs sign 0x<message>
import { createHash, createPrivateKey, sign } from 'node:crypto';

const SEED = 'swarm-derby test house key v1';
const E = 65537n;
const SMALL = [];
for (let i = 3; i < 2000; i += 2) if (SMALL.every((p) => i % p !== 0)) SMALL.push(i);

function modPow(b, e, m) {
  let r = 1n;
  for (b %= m; e > 0n; e >>= 1n, b = (b * b) % m) if (e & 1n) r = (r * b) % m;
  return r;
}

function isProbablePrime(n) {
  for (const p of SMALL) if (n % BigInt(p) === 0n) return false;
  let d = n - 1n, s = 0;
  while (!(d & 1n)) { d >>= 1n; s++; }
  for (const a of SMALL.slice(0, 20)) {
    let x = modPow(BigInt(a), d, n);
    if (x === 1n || x === n - 1n) continue;
    let i = 1;
    for (; i < s; i++) { x = (x * x) % n; if (x === n - 1n) break; }
    if (i === s) return false;
  }
  return true;
}

function prime(tag) {
  for (let i = 0; ; i++) {
    const h = Buffer.concat([0, 1, 2, 3].map((k) => createHash('sha256').update(`${SEED}|${tag}|${i}|${k}`).digest()));
    h[0] |= 0xc0;
    h[127] |= 1;
    const n = BigInt('0x' + h.toString('hex'));
    if ((n - 1n) % E !== 0n && isProbablePrime(n)) return n;
  }
}

function inverse(a, m) {
  let [r0, r1, t0, t1] = [m, a % m, 0n, 1n];
  while (r1) { const q = r0 / r1; [r0, r1] = [r1, r0 - q * r1]; [t0, t1] = [t1, t0 - q * t1]; }
  return ((t0 % m) + m) % m;
}

const b64 = (x) => Buffer.from(x.toString(16).padStart(Math.ceil(x.toString(16).length / 2) * 2, '0'), 'hex').toString('base64url');
const p = prime('p');
const q = prime('q');
const n = p * q;
const d = inverse(E, (p - 1n) * (q - 1n));
const key = createPrivateKey({
  format: 'jwk',
  key: { kty: 'RSA', n: b64(n), e: b64(E), d: b64(d), p: b64(p), q: b64(q),
    dp: b64(d % (p - 1n)), dq: b64(d % (q - 1n)), qi: b64(inverse(q, p)) },
});

const [cmd, arg] = process.argv.slice(2);
if (cmd === 'modulus') process.stdout.write('0x' + n.toString(16).padStart(512, '0'));
else if (cmd === 'exponent') process.stdout.write('0x' + d.toString(16).padStart(512, '0'));
else if (cmd === 'sign') process.stdout.write('0x' + sign('sha256', Buffer.from(arg.slice(2), 'hex'), key).toString('hex'));
else throw new Error('usage: modulus | exponent | sign 0x<message>');
