# House service (SwarmDerby v2)

Draws every swing: for each `SwingCommitted` it signs `drawMessage(swingId)` with the house
RSA key (RSASSA-PKCS1-v1_5, SHA-256) and sends `draw(swingId, sig)`. The contract checks the
signature against `houseKey`. Design: `DEPLOY.md`.

## Set up

```
cd house && npm ci
node keygen.mjs /secure/house-key.pem      # prints the 256-byte modulus for the constructor
```

- The private key file is written with mode 600 and must never enter a repo, a log or a chat.
  Anyone who holds it can see the draw of a planned swing before sending it: **the holder of
  the house key must not play.**
- The gas account is a fresh wallet that holds a little ETH on Robinhood Chain and no IMD. A
  `draw` costs about 87,000 gas. Put its private key (`0x…`) alone in a file with mode 600.

## Run

```
DERBY=0x… HOUSE_KEY_FILE=/secure/house-key.pem GAS_KEY_FILE=/secure/gas-key node house.mjs
```

| Variable | Default | |
|---|---|---|
| `DERBY` | (required) | the SwarmDerby v2 address |
| `HOUSE_KEY_FILE`, `GAS_KEY_FILE` | (required) | the two key files |
| `RPC_URL` | `https://rpc.mainnet.chain.robinhood.com` | simulates and sends each draw |
| `CHECK_RPC_URLS` | dRPC, PublicNode and thirdweb public RPCs | more RPCs that report each swing; also used to send a draw when `RPC_URL` fails |
| `QUORUM` | 3 | how many RPCs must report a swing the same way before it is signed |
| `CHAIN_ID` | 4663 | the only chain the service signs for |
| `MAX_GWEI` | 1 | the highest gas price of a `draw` |
| `LOW_ETH` | 0.0002 | alert when the gas account holds less |
| `ALERT_CMD` | none | shell command run with `$ALERT` set, for each alert (the same kind at most every 10 minutes) |

The service refuses to start if the RPC is another chain or if the key file does not match
`houseKey()`. Run it under a process manager that restarts it, for example
`pm2 start house.mjs --name <name>`. On start it scans back far enough to draw every swing
that is still inside `DRAW_WINDOW` (5 minutes), so a restart loses no swing.

## Rules it keeps

- A swing is signed only when `QUORUM` RPCs report it the same way (player, commit, league,
  status, commit time, and `nextSwingId` past it). Any RPC that disagrees stops the signature
  and raises an alert. One dishonest RPC can't get a signature for a swing that does not
  exist yet; with one, a partner player could pick a salt that wins.
- The message is built from `DRAW_TAG` (fixed in the service and checked against the contract
  at start), the chain id, the contract and those agreed swing fields.
- A signature stays secret until its `draw` is sent. It goes only into the `eth_call` that
  simulates the draw on `RPC_URL` and into the transaction. Errors are logged by their short
  message, because the full ethers message holds the calldata.
- Every `draw` is simulated before it is sent, with gas from an estimate plus 50%. The next
  swing does not wait for a draw to be mined. A `draw` that is mined and reverts raises an
  alert.
- Alerts: the gas account runs low, `houseKey()` no longer matches the key file (changed or
  revoked), the gas price is above `MAX_GWEI`, or a swing leaves the draw window undrawn.

## If the house stops

No draw within 5 minutes gives the player the turn back through `expire` (the game page, the
bot and the MCP server do this). Players lose time, not IMD. To stop draws at once, the owner
calls `revokeHouseKey()`; a new key takes effect 2 days after `proposeHouseKey`.
