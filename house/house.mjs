#!/usr/bin/env node
// SwarmDerby v2 house service: signs drawMessage(swingId) for every
// committed swing with the house RSA key and sends draw(swingId, sig).
//
//   HOUSE_KEY_FILE=/secure/house-key.pem   # RSA private key (PKCS#8 PEM) from keygen.mjs
//   GAS_KEY_FILE=/secure/gas-key           # 0x private key of the gas account: a little ETH, no IMD
//   DERBY=0x...                            # SwarmDerby v2
//   node house/house.mjs
//
// Optional: RPC_URL (default: the Robinhood Chain RPC; it simulates and sends the draws),
// CHECK_RPC_URLS (comma-separated; default: three independent public RPCs), QUORUM (default 3:
// how many RPCs must report the same committed swing before the house signs it), CHAIN_ID
// (default 4663), MAX_GWEI (default 1), LOW_ETH (default 0.0002: alert below this gas balance),
// ALERT_CMD (a shell command run with $ALERT set, for example a push to the operator).
//
// The house signs a swing only when QUORUM RPCs report it identically, so one dishonest RPC
// can't get a signature for a swing that does not exist. A signature stays secret until its
// draw is sent. It goes only into the eth_call that simulates the draw on RPC_URL and into the
// draw transaction, never into a log or a file. Errors are logged by their short message only,
// because ethers puts the calldata in the full message.

import fs from 'node:fs';
import { execFile } from 'node:child_process';
import { createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { ethers } from 'ethers';

const env = (k, d) => process.env[k] ?? d;
const CHAIN_ID = Number(env('CHAIN_ID', '4663'));
const MAX_FEE = ethers.parseUnits(env('MAX_GWEI', '1'), 'gwei');
const LOW_ETH = ethers.parseEther(env('LOW_ETH', '0.0002'));
const CHECK_RPCS = env('CHECK_RPC_URLS', 'https://robinhood.drpc.org,https://robinhood-rpc.publicnode.com,https://4663.rpc.thirdweb.com')
  .split(',').map((u) => u.trim()).filter(Boolean);
const RPCS = [env('RPC_URL', 'https://rpc.mainnet.chain.robinhood.com'), ...CHECK_RPCS];
const QUORUM = Number(env('QUORUM', '3'));
const TICK_MS = 1000;
const RESEND_S = 20; // a draw sent this long ago and still not mined may be sent again
const ALERT_EVERY_S = 600; // the same kind of alert at most this often
const COMMITTED = 1n, DRAWN = 2n; // Status: None, Committed, Drawn, Final, Refunded
// The contract's DRAW_TAG. Fixed here, so no RPC answer goes into the signed message except
// the swing fields that QUORUM RPCs agree on.
const DRAW_TAG = ethers.id('SwarmDerby.draw.v1');

const ABI = [
  'function houseKey() view returns (bytes)',
  'function DRAW_WINDOW() view returns (uint256)',
  'function DRAW_TAG() view returns (bytes32)',
  'function nextSwingId() view returns (uint256)',
  'function swings(uint256) view returns (address player, uint8 league, uint8 quality, uint8 velo, uint8 status, uint64 committedAt, bytes32 commit, uint32 day, bytes32 drawHash)',
  'function draw(uint256 swingId, bytes sig)',
  'event SwingCommitted(uint256 indexed swingId, address indexed player, uint8 league, uint8 quality, uint8 velo, uint64 committedAt)'
];

const log = (...a) => console.log(new Date().toISOString(), ...a);
const errText = (e) => e?.shortMessage || e?.code || 'error';
const lastAlert = new Map(); // kind -> unix seconds
function alert(message, kind) {
  const now = Date.now() / 1000;
  if (kind && now < (lastAlert.get(kind) ?? 0) + ALERT_EVERY_S) return;
  if (kind) lastAlert.set(kind, now);
  console.error(new Date().toISOString(), 'ALERT', message);
  const cmd = env('ALERT_CMD');
  if (cmd) execFile('sh', ['-c', cmd], { env: { ...process.env, ALERT: message }, timeout: 30_000 }, () => {});
}

let DERBY, houseKey, gasKey;
try {
  DERBY = ethers.getAddress(env('DERBY', ''));
  houseKey = createPrivateKey(fs.readFileSync(env('HOUSE_KEY_FILE', ''), 'utf8'));
  gasKey = fs.readFileSync(env('GAS_KEY_FILE', ''), 'utf8').trim();
  new ethers.Wallet(gasKey);
} catch (e) {
  // Never print the error: it can hold key material.
  console.error('Set DERBY, HOUSE_KEY_FILE (PKCS#8 PEM from keygen.mjs) and GAS_KEY_FILE (0x private key). See house/README.md.');
  process.exit(1);
}
const modulus = '0x' + Buffer.from(createPublicKey(houseKey).export({ format: 'jwk' }).n, 'base64url').toString('hex');

const rpcs = RPCS.map((url) => {
  const provider = new ethers.JsonRpcProvider(url, undefined, { staticNetwork: ethers.Network.from(CHAIN_ID), cacheTimeout: -1 });
  provider.pollingInterval = 250;
  const wallet = new ethers.Wallet(gasKey, provider);
  return { provider, wallet, derby: new ethers.Contract(DERBY, ABI, wallet) };
});

if (RPCS.length < QUORUM || QUORUM < 1) {
  console.error(`QUORUM ${QUORUM} needs at least that many RPCs (RPC_URL plus CHECK_RPC_URLS)`);
  process.exit(1);
}

let drawWindow, nextBlock, gasLimit = 300_000n, ticks = 0;
const pending = new Map(); // swingId -> committedAt, from SwingCommitted logs
const sent = new Map(); // swingId -> unix seconds of the last draw sent

/** The first block to scan: far enough back to see every swing still inside DRAW_WINDOW. */
async function firstBlock(provider) {
  const latest = await provider.getBlock('latest');
  for (let step = 1024; ; step *= 2) {
    const n = Math.max(0, latest.number - step);
    if (n === 0 || (await provider.getBlock(n)).timestamp < latest.timestamp - drawWindow) return n;
  }
}

async function scan({ provider, derby }) {
  const latest = await provider.getBlock('latest');
  while (nextBlock <= latest.number) {
    const to = Math.min(latest.number, nextBlock + 4999);
    for (const l of await derby.queryFilter(derby.filters.SwingCommitted(), nextBlock, to)) {
      pending.set(l.args.swingId, Number(l.args.committedAt));
    }
    nextBlock = to + 1;
  }
  return latest.timestamp;
}

const same = (a, b) => a.player === b.player && a.commit === b.commit && a.status === b.status
  && a.committedAt === b.committedAt && a.league === b.league;

/** The swing as QUORUM RPCs report it, or null. Any RPC that disagrees stops the draw. */
async function agreedSwing(id) {
  const reads = await Promise.all(rpcs.map(async ({ derby }) => {
    try {
      const [s, next] = await Promise.all([derby.swings(id), derby.nextSwingId()]);
      return next > id ? s : null;
    } catch { return null; }
  }));
  const seen = reads.filter(Boolean);
  if (seen.length === 0) return null;
  if (seen.some((s) => !same(s, seen[0]))) {
    alert(`RPCs disagree about swing #${id}; not signing it`, 'disagree');
    return null;
  }
  return seen.length >= QUORUM ? seen[0] : null;
}

async function drawOne(id, chainNow) {
  const last = sent.get(id);
  if (last && chainNow < last + RESEND_S) return;
  const s = await agreedSwing(id);
  if (!s) return; // not yet seen by QUORUM RPCs; the next tick tries again
  if (s.status !== COMMITTED) {
    if (s.status === DRAWN && !last) log(`#${id} was drawn by someone else`);
    pending.delete(id); sent.delete(id);
    return;
  }
  const message = ethers.AbiCoder.defaultAbiCoder().encode(
    ['bytes32', 'uint256', 'address', 'uint256', 'address', 'bytes32'],
    [DRAW_TAG, CHAIN_ID, DERBY, id, s.player, s.commit]);
  const sig = sign('sha256', ethers.getBytes(message), houseKey);
  const { derby } = rpcs[0];
  try {
    await derby.draw.staticCall(id, sig); // simulate on RPC_URL: a draw must never land and revert
    gasLimit = (await derby.draw.estimateGas(id, sig)) * 3n / 2n;
  } catch (e) {
    log(`draw #${id} simulation failed: ${errText(e)}`);
    return;
  }
  for (const [i, r] of rpcs.entries()) {
    try {
      const tx = await r.derby.draw(id, sig, { gasLimit, maxFeePerGas: MAX_FEE, maxPriorityFeePerGas: 0n });
      sent.set(id, chainNow);
      // Not awaited: the next swing does not wait for this one to be mined.
      tx.wait(1, 120_000).then(
        (rc) => (rc.status === 1 ? log(`drew #${id} in block ${rc.blockNumber}, tx ${tx.hash}`) : alert(`draw #${id} reverted on-chain: ${tx.hash}`)),
        (e) => log(`draw #${id} not confirmed yet (${errText(e)}), tx ${tx.hash}`));
      return;
    } catch (e) {
      log(`draw #${id} send failed on RPC ${i + 1}: ${errText(e)}`);
    }
  }
}

async function tick() {
  let chainNow;
  for (const r of rpcs) {
    try { chainNow = await scan(r); break; } catch (e) { log('scan failed:', errText(e)); }
  }
  if (chainNow === undefined) return;
  for (const [id, committedAt] of [...pending].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (chainNow > committedAt + drawWindow) {
      pending.delete(id); sent.delete(id);
      const s = await rpcs[0].derby.swings(id).catch(() => null);
      if (s?.status === COMMITTED) alert(`#${id} left the draw window undrawn; the player can expire it for a refund`, 'undrawn');
      continue;
    }
    await drawOne(id, chainNow);
  }
  if (ticks++ % 60 === 0) {
    const { provider, wallet, derby } = rpcs[0];
    const eth = await provider.getBalance(wallet.address).catch(() => null);
    if (eth !== null && eth < LOW_ETH) alert(`gas account ${wallet.address} holds only ${ethers.formatEther(eth)} ETH`, 'eth');
    const key = await derby.houseKey().catch(() => null);
    if (key !== null && key.toLowerCase() !== modulus) alert(`houseKey of ${DERBY} no longer matches HOUSE_KEY_FILE (changed or revoked): draws fail`, 'key');
    const fee = await provider.getFeeData().catch(() => null);
    if (fee?.gasPrice && fee.gasPrice > MAX_FEE) alert(`gas price ${ethers.formatUnits(fee.gasPrice, 'gwei')} gwei is above MAX_GWEI: draws wait`, 'fee');
  }
}

async function main() {
  const { provider, derby } = rpcs[0];
  if (Number(await provider.send('eth_chainId', [])) !== CHAIN_ID) throw new Error(`RPC_URL is not chain ${CHAIN_ID}`);
  if ((await derby.houseKey()).toLowerCase() !== modulus) throw new Error('HOUSE_KEY_FILE does not match the houseKey of DERBY');
  if ((await derby.DRAW_TAG()) !== DRAW_TAG) throw new Error('DERBY has another DRAW_TAG: not a SwarmDerby v2 this service knows');
  for (const [i, r] of rpcs.entries()) {
    const id = await r.provider.send('eth_chainId', []).catch(() => null);
    if (id !== null && Number(id) !== CHAIN_ID) throw new Error(`RPC ${i + 1} is not chain ${CHAIN_ID}`);
  }
  drawWindow = Number(await derby.DRAW_WINDOW());
  nextBlock = await firstBlock(provider);
  log(`house for ${DERBY} on chain ${CHAIN_ID}: gas account ${rpcs[0].wallet.address}, ${rpcs.length} RPCs, quorum ${QUORUM}, scanning from block ${nextBlock}`);
  const loop = async () => {
    try { await tick(); } catch (e) { log('tick failed:', errText(e)); }
    setTimeout(loop, TICK_MS);
  };
  loop();
}

main().catch((e) => { console.error(errText(e) === 'error' ? e.message : errText(e)); process.exit(1); });
