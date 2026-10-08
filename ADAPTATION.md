# SwarmDerby v2 launch adaptation

This adaptation prepares only `src/SwarmDerby.sol:SwarmDerby` for the
`evm_contracts` factory. No live transaction was sent. DerbyAuction, tokens,
distributors and pools are not part of this launch. The following step writes
`launch.json`; this adaptation does not create it.

## Changes and reasons

- `src/SwarmDerby.sol`: replaced the dynamic constructor key argument with eight
  consecutive `bytes32` arguments. The factory supports static arguments only.
  Concatenating the eight words restores the exact 256-byte big-endian modulus
  before the original key validation, storage and event emission. Ownership
  still comes from `owner_`, not the factory. Construction remains nonpayable
  and makes no external calls or token code check.
- `src/SwarmDerby.sol`: added `NoHouseKey()` to the shared purchase path when
  the key is revoked. This implements the final task instruction to fix
  reproduced imported audit findings (low `da912675…`). Both purchase methods,
  in both leagues and through sessions, now reject before accounting or IMD
  transfers. A pending proposal does not itself block purchases; following
  revocation, purchases resume only after activation. This is the only runtime
  behavior change.
- `test/HouseKey.sol`, `test/SwarmDerby.t.sol` and
  `test/SwarmDerbyDraw.t.sol`: adapted deployment fixtures to the static
  constructor while retaining the existing dummy and RSA test keys. The
  constructor's former short-key test now checks even moduli and moduli without
  the top bit set; a missing constructor word is covered by the launch rehearsal.
  Dynamic proposal-key length tests remain. Added purchase rejection/recovery
  tests and extended the rotation test through the refund.
- `test/SwarmDerbyLaunch.t.sol`: added a zero-value CREATE2 rehearsal using the
  exact launch modulus, token address and prices, with no token fixture.
  It checks the predicted address, explicit ownership, initialization events,
  all launch settings, runtime size and forbidden opcodes. Further tests cover
  a reverting token dependency, truncated static arguments and nonpayable
  construction.
- `e2e/setup.py`: updated the existing local rehearsal's constructor encoding
  to eight static words and rejects a modulus of the wrong length. This script
  is not the production launch plan.
- `DEPLOY.md`: corrected the constructor handoff and documented revoked-key
  purchase rejection and key rotation operations.
- `ADAPTATION.md`: records the changes, audit dispositions and exact factory
  arguments for the next step.

All runtime function signatures, events, errors, constants, EIP-712 data,
`drawMessage`, splits, launch prices and payout math are unchanged.
`src/DerbyOdds.sol` and `src/HouseDraw.sol` remain byte-identical. Build
configuration and dependencies are unchanged; no dependencies were installed.

## Constructor handoff

Use these twelve arguments in this order. Arguments 5–12 are eight separate
`bytes32` values, not an array, dynamic bytes, or text. Concatenate their bytes
without reversing or padding to recover the modulus supplied in the brief.
Each key word is 66 characters including `0x`, within the stated 96-character
manifest argument limit; the complete ABI argument encoding is 384 bytes.

| Position | Argument | Value |
| --- | --- | --- |
| 1 | `owner_` | `$owner` (resolved by the launch service) |
| 2 | `imd_` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| 3 | `singlePrice_` | `150000000000000000` |
| 4 | `packPrice_` | `500000000000000000` |
| 5 | `houseKey0_` | `0x9b7398ccc4834a29c3064efa2b3530e31022109a8dc6a654bfa878ae0059a2a2` |
| 6 | `houseKey1_` | `0xc3ac9f31916c0a320a2c179109e395905fc821aab91a1136523c1b90bce1536f` |
| 7 | `houseKey2_` | `0xe5c11ab65de79551875327766c99e74f9243761f0b3c8d323194bd7f3da77086` |
| 8 | `houseKey3_` | `0xe27991d5ac2e46ec41b36dc3e959b99dfd40e309277beda06980f5d5d59dd86f` |
| 9 | `houseKey4_` | `0x2d3d01738e7773bfada03634ac9d8611b31f274422bf36137afdf465a406d299` |
| 10 | `houseKey5_` | `0x433bf548042816d7aa6b6f69e007bc70d5acb0db4a5c8f19cecbaf31728faa39` |
| 11 | `houseKey6_` | `0x9b0b143d34eb956a2230fe75fdaed887cbd68f7154d1abfb62204e928b9c4e9b` |
| 12 | `houseKey7_` | `0x54ab9cc7bf171f27a16aa37d8a4a7a02f54b7ab2056befbbffcfbdb24506863d` |

Do not substitute a test owner or test key. The explicit `$owner` placeholder
is resolved by the launch service, as specified by the request.

## Imported audit disposition

- **Medium `98132ac6…`: reproduced and fixed.** The original compiled ABI
  has a fifth argument of type `bytes`. The provided key is 256 bytes
  (514 hex-string characters), conflicting with the supplied static-only
  factory rules and stated string limit. The local input does not include the
  manifest validator, so no claim is made to have executed that validator.
  The static-word CREATE2 test checks the actual replacement encoding.
- **Low `da912675…`: reproduced and fixed.** On the original code, a
  revoked-key purchase credited one turn and sent 0.06 IMD to the burn
  address; the contact swing then reverted `NoHouseKey()`. A scratch test
  reproduced this before the change. Permanent tests cover singles, packs,
  both leagues, sessions, unchanged balances/allowances/accounting on rejection,
  active-key proposals and recovery after activation.
- **Info `e63821e9…`: reproduced; runtime unchanged.** Permissionless
  activation invalidates an old-key signature, and expiration refunds the turn
  and arcade slot. Reproduced on the original code and retained in the
  extended rotation regression. One detail of the report is inaccurate:
  `house/house.mjs` checks the on-chain modulus approximately every 60 ticks
  to alert on a mismatch; it does not load a new signing key automatically.
  The operator must switch/restart the service with the matching key at
  activation. This is documented in `DEPLOY.md`.
- **Info `5d362f1c…`: coverage statement, not a defect.** Reviewed the three
  SwarmDerby source files and the relevant house service rotation behavior.
  No critical/high finding was reproduced. The imported invariant-fuzz results
  are another contributor's evidence, not checks rerun here. DerbyAuction is
  unchanged and outside the launch; its existing tests still run.

The accepted trust assumptions in the brief remain, including house-key
prediction/withholding, client-reported swing inputs, per-wallet arcade caps,
session consent without deadlines and purchases without maxCost. The external
IMD token and Robinhood's live modexp precompile were not verified against a
live RPC in this local adaptation; the deployer's live simulation remains
necessary. All local RSA verification uses Foundry's EVM modexp precompile.

## Validation

- Original baseline: `forge test` passed all 117 tests, without FFI.
- Final `forge build`: passed with the project's unchanged configuration;
  compiler mutability and Forge lint warnings remain.
- Final `forge test`: **125 passed, 0 failed, 0 skipped**, without FFI. This
  includes the original 117 tests (with constructor fixture updates), four
  purchase regressions and four launch tests. The three existing fuzz tests
  each ran 256 cases. An initially incorrect arcade-slot expectation in the
  extended rotation test was corrected: both swings occur on the same UTC day,
  so refunding the second leaves the first slot consumed.
- Compared compiled ABIs before and after: every non-constructor entry is
  identical. Verified the new constructor has two addresses, two uint256s and
  eight bytes32s, and remains nonpayable.
- Runtime size: **17,692 bytes**, below 24,576. Both the CREATE2 test and an
  independent PUSH-aware bytecode scan found no DELEGATECALL, CALLCODE or
  SELFDESTRUCT opcodes.
- Byte comparisons confirmed `DerbyOdds.sol`, `HouseDraw.sol`,
  `DerbyAuction.sol` and `foundry.toml` are unchanged. Source comparison from
  the end of the constructor confirms the sole runtime change is the purchase
  guard.
- Checked `e2e/setup.py` syntax and executed its revised encoding statements
  with `cast abi-encode`: exactly 384 bytes matching the supplied modulus;
  short, long and malformed hex keys reject. No devnet token was deployed.
- Verified the eight documented key words concatenate to the exact launch
  modulus and checked the diff for whitespace errors. No Slither/Mythril,
  browser E2E session, live-chain deployment or live-chain token check ran.
