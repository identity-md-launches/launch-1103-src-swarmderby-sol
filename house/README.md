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
DERBY=0x… HOUSE_KEY_FILE=/secure/house-key.pem GAS_KEY_FILE=/secure/gas-key \
RPC_URL_2=https://… node house.mjs
```

| Variable | Default | |
|---|---|---|
| `DERBY` | (required) | the SwarmDerby v2 address |
| `HOUSE_KEY_FILE`, `GAS_KEY_FILE` | (required) | the two key files |
| `RPC_URL` | `https://rpc.mainnet.chain.robinhood.com` | |
| `RPC_URL_2` | none | a second RPC, used when the first fails |
| `CHAIN_ID` | 4663 | the only chain the service signs for |
| `MAX_GWEI` | 1 | the highest gas price of a `draw` |
| `LOW_ETH` | 0.0002 | alert when the gas account holds less |
| `ALERT_CMD` | none | shell command run with `$ALERT` set, for each alert |

The service refuses to start if the RPC is another chain or if the key file does not match
`houseKey()`. Run it under a process manager that restarts it, for example
`pm2 start house.mjs --name <name>`. On start it scans back far enough to draw every swing
that is still inside `DRAW_WINDOW` (5 minutes), so a restart loses no swing.

## Rules it keeps

- A signature stays secret until its `draw` is mined. It goes only into the `eth_call` that
  simulates the draw and into the transaction. Errors are logged by their short message,
  because the full ethers message holds the calldata.
- The message is built from the swing (`DRAW_TAG`, chain id, contract, swing id, player,
  commit), never read from the RPC.
- Every `draw` is simulated before it is sent, with gas from an estimate plus 50%. A `draw`
  that is mined and reverts raises an alert.
- Use RPCs you trust. An RPC that lies about a swing could get the house to sign a draw for
  a swing that does not exist yet.

## If the house stops

No draw within 5 minutes gives the player the turn back through `expire` (the game page, the
bot and the MCP server do this). Players lose time, not IMD. To stop draws at once, the owner
calls `revokeHouseKey()`; a new key takes effect 2 days after `proposeHouseKey`.
