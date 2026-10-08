# End-to-end test (local devnet)

Runs the real game page, the reference bot and the house service against SwarmDerby v2 on a
local devnet, with a scripted wallet. Needs Foundry (anvil, cast, forge), Node and Python
Playwright (`pip install playwright==1.55.0`, Chromium 140). The devnet uses anvil's default
chain id 31337, the page's local network. Run the scripts in this order on a fresh devnet.

```
cp e2e/Mocks.sol src/Mocks.sol && forge build          # test IMD (MockIMD)
anvil --silent &
node house/keygen.mjs /tmp/house-key.pem               # prints the house modulus
HOUSE_MODULUS=<modulus> python3 e2e/setup.py           # deploys MockIMD + SwarmDerby v2, writes e2e/addrs.json
(cd house && npm ci && DERBY=<derby> HOUSE_KEY_FILE=/tmp/house-key.pem GAS_KEY_FILE=<file with anvil key #2> \
  RPC_URL=http://127.0.0.1:8545 CHECK_RPC_URLS= QUORUM=1 CHAIN_ID=31337 MAX_GWEI=10 node house.mjs &)
RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=<anvil key #1> DERBY=<derby> IMD=<imd> CHAIN_ID=31337 MAX_GWEI=10 \
  MAX_IMD=1 MAX_SWINGS=3 node ../swarm-derby-site/agent-bot.mjs
export HOUSE_PID=<pid of node house.mjs>              # recover.py and refund.py pause the house
python3 e2e/play.py                                    # connect, buy, quick swings, swing, miss
python3 e2e/recover.py                                 # reload before the draw, reveal on return
python3 e2e/recover_unmined.py                         # reload before the commit receipt arrives
python3 e2e/board.py                                   # leaderboard + pot match the contract (next day)
python3 e2e/leagues.py                                 # 20-swing cap, arcade vs agent boards (next day)
python3 e2e/settle.py                                  # the days end; a stranger pays both leagues
python3 e2e/refund.py                                  # no draw in 5 minutes: the page gives the turn back
```

Without `HOUSE_MODULUS`, `setup.py` uses the fixed test key of `test/fixtures/house-test-key.mjs`
(the house service needs a PEM file, so make a key with `keygen.mjs` for a run with the house).
`board.py` and `leagues.py` move the devnet clock to the next UTC day first, and `settle.py`
pays every finished day, so the chain clock ends days ahead of the real one; `refund.py` then
shows that the page counts the draw window in chain time.

Check out the site repo next to this one as `../swarm-derby-site/`, or set `SITE=/path/to/index.html`.
The page only accepts `?network=local&derby=…&imd=…&rpc=…` overrides for the local devnet.
Remove `src/Mocks.sol` before deploying.
