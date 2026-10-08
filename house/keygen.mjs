#!/usr/bin/env node
// Makes the house RSA key pair (2048-bit, e = 65537) for SwarmDerby v2.
//   node house/keygen.mjs /secure/path/house-key.pem
// Writes the private key (PKCS#8 PEM, mode 600) to the path, which must not exist yet, and
// prints the 256-byte modulus: the `houseKey` constructor argument (or proposeHouseKey).
import fs from 'node:fs';
import { generateKeyPairSync } from 'node:crypto';

const file = process.argv[2];
if (!file) { console.error('usage: node house/keygen.mjs <private-key-file>'); process.exit(1); }
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048, publicExponent: 65537 });
fs.writeFileSync(file, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600, flag: 'wx' });
const n = Buffer.from(publicKey.export({ format: 'jwk' }).n, 'base64url');
if (n.length !== 256) throw new Error('modulus is not 256 bytes');
console.log('0x' + n.toString('hex'));
