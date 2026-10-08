# Additional SwarmDerby coverage

Run with `forge build` and `forge test`. The added tests require no network, FFI,
environment variables, or additional dependencies. Existing tests are retained.

`SwarmDerbyFailures.t.sol` exercises failed token pulls, malformed return data,
rollback after a rejected burn or ops withdrawal, insufficient allowance, maximum
purchase counts, admin authorization, invalid leagues, failed settlement tips,
unpayable winners, commit reuse after refund, refunds across midnight, exact
draw/reveal deadlines, chain-bound signatures, key proposal replacement, and
session consent validation. The two fuzz properties run 1,000 cases each.

`SwarmDerbyInvariant.t.sol` targets only its handler, with 256 sequences of 64
calls per invariant and unexpected reverts treated as failures. Four players and
their session keys buy, swing, draw, reveal, expire, donate, change prices,
withdraw ops, and settle days in random order. Time only moves forward. The
handler uses real RSA signatures and the unmodified application's public API;
it does not inject scores or bypass signature verification.

The invariants check:

- Token holdings equal pots, vaults, ops, and separately tracked donations.
  Purchases and donations equal held tokens plus burns and external payouts.
  Player and session balances agree with independent spend/payment records.
- Each league's pot equals its open daily pots plus rollover. Queues are ordered,
  a day settles once, and settled boards cannot change.
- Purchased turns equal remaining turns plus turns spent without refunds.
  Refunds restore only their original day's cap slot. Terminal swing counts
  agree with the handler, and commits remain consumed.
- Scores match finalized outcomes, boards contain each scorer once in descending
  order, and session mappings remain reciprocal.

The offline token ledger reuses `MockIMD` from the existing suite. Its runtime is
installed with `vm.etch` at the brief's IMD address; no token constructor is run.
Malformed payment simulations refuse the transfer without moving tokens. These
tests do not claim support for fee-on-transfer, rebasing, or malicious token
implementations. Live Robinhood Chain token behavior still requires integration
verification against chain state.

The public RSA key and session signing keys used here are test fixtures only.
Exact production constructor arguments, including the supplied house modulus,
remain covered by the existing `SwarmDerbyLaunch.t.sol` empty-chain rehearsal.
This assignment does not broadcast a deployment or test the off-chain house
service, and adds no deployment of DerbyAuction, a distributor, or a pool.
