// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DerbyOdds} from "./DerbyOdds.sol";
import {HouseDraw} from "./HouseDraw.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SwarmDerby
/// @notice One-button batting cage on Robinhood Chain, paid in IMD, in two leagues:
///
///  ARCADE (0)  people playing the game page. Max 20 swings per wallet per UTC day.
///              Ranked by each player's LONGEST homer of the day.
///  AGENT  (1)  bots and AI agents playing straight against the contract, no cap.
///              Ranked by TOTAL homer feet for the day.
///
///  Each league has its own turns, pots, slam vault, scoreboard and daily settlement, so
///  agent volume never dilutes the arcade prize. On-chain a script and a person look the
///  same: the cap makes out-spending humans expensive, it does not make it impossible.
///
///  Turns:   1 turn for 0.15 IMD or a 5-turn pack for 0.5 IMD (owner-adjustable, never under
///           MIN_TURN_PRICE a turn). Every purchase is split 40% burned, 45% to that league's
///           pot for the UTC day of the purchase, 10% to its slam vault, 5% ops.
///  Swings:  swing(league, quality, velo, commit), commit = keccak256(abi.encode(salt, player)).
///           The house then signs the swing with its RSA key and calls draw(swingId, sig); the
///           contract checks the signature (HouseDraw), and the player calls finalize(swingId,
///           salt). The roll uses keccak256(salt, keccak256(sig)). The player can't make the
///           signature, the house can't choose it (one valid signature per swing) and doesn't
///           know the salt, and an unrevealed draw counts as a foul, so nobody can steer a roll
///           and hiding a bad one never pays. No draw within DRAW_WINDOW gives the turn back.
///           A swing scores on the UTC day it was committed.
///  Slams:   a 550+ ft swing pays 10% of its league's vault instantly.
///  Daily:   the contract's own board ranks each day. Once a day is over and its last swing
///           can no longer be drawn or revealed, anyone calls settleNextDay(league): that day's top 3
///           are paid 60 / 25 / 15 from 90% of the day's pot (plus anything rolled over), the
///           caller earns 0.5% of that payout, and the rest rolls over to the next day.
///           Days settle in order, each exactly once.
contract SwarmDerby {
    // ───────── constants ─────────
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 public constant ARCADE = 0;
    uint8 public constant AGENT = 1;
    uint256 public constant ARCADE_DAILY_CAP = 20;

    uint256 public constant PACK_SIZE = 5;
    uint256 public constant MIN_TURN_PRICE = 0.01 ether;
    uint256 public constant BURN_BPS = 4000;
    uint256 public constant POT_BPS = 4500;
    uint256 public constant VAULT_BPS = 1000; // ops gets the remaining 500
    uint256 public constant SLAM_VAULT_SHARE_BPS = 1000;
    uint256 public constant PAYOUT_BPS = 9000; // share of a day's pot paid out; 10% rolls over
    uint256 public constant SETTLE_TIP_BPS = 50;

    /// @notice The house must draw a swing within this time of its commit, or the turn comes back.
    uint256 public constant DRAW_WINDOW = 5 minutes;
    /// @notice After DRAW_WINDOW + REVEAL_WINDOW from the commit, an unrevealed draw counts as a foul.
    uint256 public constant REVEAL_WINDOW = 5 minutes;
    bytes32 public constant DRAW_TAG = keccak256("SwarmDerby.draw.v1");
    /// @notice A new house key takes effect only this long after the owner proposes it, so
    ///         players can see a key change coming and stop playing.
    uint256 public constant KEY_DELAY = 2 days;
    uint256 public constant BOARD_SIZE = 10;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SESSION_TYPEHASH = keccak256("Session(address player,address session,uint256 nonce)");

    // ───────── types ─────────
    enum Status { None, Committed, Drawn, Final, Refunded }

    struct Swing {
        address player;
        uint8 league;
        uint8 quality;
        uint8 velo;
        Status status;
        uint64 committedAt; // block.timestamp of the commit
        bytes32 commit;
        uint32 day; // UTC day of the commit: the day the swing counts for
        bytes32 drawHash; // keccak256 of the house signature, set by draw
    }

    // ───────── state ─────────
    IERC20 public immutable imd;
    address public owner;
    address public pendingOwner; // named by transferOwnership, takes over on acceptOwnership
    uint256 public singlePrice; // per turn
    uint256 public packPrice;   // per PACK_SIZE turns

    /// @notice Everything a league holds for prizes: every unsettled day's pot plus rollover.
    uint256[2] public pot;
    uint256[2] public vault;
    uint256 public opsBalance;
    /// @notice The house RSA public key: a 2048-bit modulus (e = 65537). See HouseDraw.
    ///         Empty after revokeHouseKey: then no swing can be drawn and every swing is refunded.
    bytes public houseKey;
    bytes public pendingHouseKey;    // proposed by the owner
    uint256 public pendingHouseKeyAt; // when pendingHouseKey can be activated; 0 if none
    /// @notice Commits already used. A reused salt would show the house a pending result.
    mapping(bytes32 => bool) public commitUsed;
    mapping(uint8 => mapping(address => uint256)) public turns; // league => player => turns
    mapping(uint256 => mapping(address => uint256)) public arcadeSwings; // day => player => swings

    /// @notice Session keys: a throwaway key a player authorizes to swing on their turns
    ///         without wallet popups. It can only spend turns and reveal; every homer,
    ///         slam payout and leaderboard credit goes to the player. Binding needs the
    ///         key's own signature, and the key can leave at any time.
    mapping(address => address) public sessionPlayer; // session key -> player
    mapping(address => address) public sessionOf;     // player -> session key
    mapping(address => uint256) public sessionNonce;  // session key -> binds so far

    /// @notice Scoreboards. Arcade: each player's longest homer of the day. Agent: total
    ///         homer feet of the day. `board` keeps the day's top BOARD_SIZE, highest first,
    ///         and pays its top 3 when the day is settled.
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public dayScore;
    mapping(uint8 => mapping(uint256 => address[])) internal _board;

    mapping(uint256 => Swing) public swings;
    uint256 public nextSwingId;

    /// @notice Daily settlement. Each UTC day with a purchase or a swing joins its league's
    ///         queue of days; settleNextDay pays them in order.
    mapping(uint8 => mapping(uint256 => uint256)) public dayPot;     // league => day => pot share of that day's purchases
    mapping(uint8 => mapping(uint256 => uint64)) public dayLastCommit; // league => day => timestamp of its last swing
    mapping(uint8 => uint256[]) internal _days;                      // league => days with activity, oldest first
    uint256[2] public settledDays;                                   // league => days settled from the front of _days
    uint256[2] public rollover;                                      // league => carried into the next settled day

    // ───────── events ─────────
    event TurnsBought(address indexed player, uint8 indexed league, uint256 count, uint256 cost, uint256 burned);
    event SessionSet(address indexed player, address indexed session);
    event SwingCommitted(uint256 indexed swingId, address indexed player, uint8 league, uint8 quality, uint8 velo, uint64 committedAt);
    event SwingDrawn(uint256 indexed swingId, bytes32 drawHash);
    event SwingRefunded(uint256 indexed swingId, address indexed player, uint8 league);
    event HouseKeySet(bytes32 keyHash); // bytes32(0) when revoked
    event HouseKeyProposed(bytes32 keyHash, uint256 activeAt);
    event SwingResolved(uint256 indexed swingId, address indexed player, uint8 tier, uint16 feet);
    /// @notice Every homer, either league, credited to the UTC day of its commit.
    event Dinger(address indexed player, uint8 indexed league, uint256 indexed day, uint256 feet);
    event GrandSlam(uint256 indexed swingId, address indexed player, uint8 league, uint16 feet, uint256 payout);
    /// @param amounts what each winner received (0 if the token refused the transfer)
    /// @param rollover the league's rollover after this day: what the next day starts with
    event DaySettled(uint8 indexed league, uint256 indexed day, address[] winners, uint256[] amounts,
        address settler, uint256 tip, uint256 rollover);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error BadLeague();
    error BadPrice();
    error NoTurns();
    error DailyCapReached();
    error BadQuality();
    error BadCommit();
    error BadSalt();
    error WrongStatus();
    error NotExpired();
    error BadDraw();
    error DrawClosed();
    error BadKey();
    error CommitUsed();
    error KeyNotReady();
    error BadSession();
    error TransferFailed();
    error NothingToSettle();
    error DayNotOver();
    error ZeroAddress();
    error NotAContract();
    error ZeroCount();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier validLeague(uint8 league) {
        if (league > AGENT) revert BadLeague();
        _;
    }

    /// @param owner_ admin address. Pass it explicitly: when IMD's launch factory deploys
    ///               this, msg.sender is the factory (use `$owner` in the launch request).
    /// @param houseKey_ the house RSA modulus, 256 bytes big-endian (e = 65537)
    constructor(address owner_, IERC20 imd_, uint256 singlePrice_, uint256 packPrice_, bytes memory houseKey_) {
        if (owner_ == address(0) || address(imd_) == address(0)) revert ZeroAddress();
        _checkPrices(singlePrice_, packPrice_);
        _checkKey(houseKey_);
        houseKey = houseKey_;
        emit HouseKeySet(keccak256(houseKey_));
        imd = imd_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        singlePrice = singlePrice_;
        packPrice = packPrice_;
    }

    // ───────── turns ─────────

    /// @notice Buy single turns in a league at singlePrice each.
    function buyTurns(uint8 league, uint256 count) external validLeague(league) {
        _buy(league, count, count * singlePrice);
    }

    /// @notice Buy packs of PACK_SIZE turns in a league at packPrice each.
    function buyPacks(uint8 league, uint256 packs) external validLeague(league) {
        _buy(league, packs * PACK_SIZE, packs * packPrice);
    }

    /// @dev The caller pays; the turns go to the player it acts for, so a session key
    ///      buying turns tops up its player instead of stranding them on the key.
    function _buy(uint8 league, uint256 count, uint256 cost) internal {
        if (count == 0) revert ZeroCount();
        address player = playerOf(msg.sender);
        uint256 burned = (cost * BURN_BPS) / 10_000;
        uint256 toPot = (cost * POT_BPS) / 10_000;
        uint256 toVault = (cost * VAULT_BPS) / 10_000;
        uint256 day = currentDay();

        turns[league][player] += count;
        _markDay(league, day);
        dayPot[league][day] += toPot;
        pot[league] += toPot;
        vault[league] += toVault;
        opsBalance += cost - burned - toPot - toVault;

        _pull(msg.sender, cost);
        _send(DEAD, burned);
        emit TurnsBought(player, league, count, cost, burned);
    }

    // ───────── sessions ─────────

    /// @notice What a session key signs (EIP-712) to agree to swing for `player`.
    function sessionDigest(address player, address session) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(
            DOMAIN_TYPEHASH, keccak256("SwarmDerby"), keccak256("1"), block.chainid, address(this)
        ));
        bytes32 structHash = keccak256(abi.encode(SESSION_TYPEHASH, player, session, sessionNonce[session]));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @notice Authorize (or with address(0), revoke) a session key for msg.sender.
    /// @param consent the key's EIP-712 signature over sessionDigest(msg.sender, session);
    ///                ignored when revoking.
    function setSession(address session, bytes calldata consent) external {
        if (sessionPlayer[msg.sender] != address(0)) revert BadSession(); // keys can't have keys
        address old = sessionOf[msg.sender];
        if (old != address(0)) delete sessionPlayer[old];
        if (session != address(0)) {
            if (session == msg.sender || sessionPlayer[session] != address(0) || sessionOf[session] != address(0)) {
                revert BadSession();
            }
            if (_recover(sessionDigest(msg.sender, session), consent) != session) revert BadSession();
            sessionNonce[session] += 1;
            sessionPlayer[session] = msg.sender;
        }
        sessionOf[msg.sender] = session;
        emit SessionSet(msg.sender, session);
    }

    /// @notice A session key ends its own session.
    function leaveSession() external {
        address player = sessionPlayer[msg.sender];
        if (player == address(0)) revert BadSession();
        delete sessionPlayer[msg.sender];
        delete sessionOf[player];
        emit SessionSet(player, address(0));
    }

    /// @notice The player a caller acts for: itself, or the player that authorized it.
    function playerOf(address caller) public view returns (address) {
        address p = sessionPlayer[caller];
        return p == address(0) ? caller : p;
    }

    // ───────── swings ─────────

    /// @notice The commit a player sends with a swing. Compute it off-chain (same encoding).
    function commitFor(bytes32 salt, address player) public pure returns (bytes32) {
        return keccak256(abi.encode(salt, player));
    }

    /// @notice Swings left today for an arcade player (the cap resets at 00:00 UTC).
    function arcadeSwingsLeft(address player) external view returns (uint256) {
        uint256 used = arcadeSwings[currentDay()][player];
        return used >= ARCADE_DAILY_CAP ? 0 : ARCADE_DAILY_CAP - used;
    }

    /// @param league  ARCADE or AGENT; spends a turn from that league.
    /// @param quality 0 for a miss, 1-100 for contact (from exit velo + timing). Higher is
    ///                never worse; see DerbyOdds.
    /// @param velo    exit-velo score 0-100; under DerbyOdds.POWER_LINE no bomb or slam is possible.
    /// @param commit  commitFor(salt, player) for a fresh random salt; ignored on a miss.
    ///                `player` is the account whose turns are spent (playerOf(msg.sender)).
    function swing(uint8 league, uint8 quality, uint8 velo, bytes32 commit)
        external
        validLeague(league)
        returns (uint256 swingId)
    {
        if (quality > 100 || velo > 100) revert BadQuality();
        address player = playerOf(msg.sender);
        if (turns[league][player] == 0) revert NoTurns();
        uint256 day = currentDay();
        if (league == ARCADE) {
            if (arcadeSwings[day][player] >= ARCADE_DAILY_CAP) revert DailyCapReached();
            arcadeSwings[day][player] += 1;
        }
        turns[league][player] -= 1;

        swingId = nextSwingId++;
        if (quality == 0) {
            swings[swingId] = Swing(player, league, 0, velo, Status.Final, 0, bytes32(0), uint32(day), bytes32(0));
            emit SwingResolved(swingId, player, DerbyOdds.WHIFF, 0);
            return swingId;
        }
        if (commit == bytes32(0)) revert BadCommit();
        if (commitUsed[commit]) revert CommitUsed();
        commitUsed[commit] = true;

        uint64 nowTs = uint64(block.timestamp);
        _markDay(league, day);
        dayLastCommit[league][day] = nowTs;
        swings[swingId] = Swing(player, league, quality, velo, Status.Committed, nowTs, commit, uint32(day), bytes32(0));
        emit SwingCommitted(swingId, player, league, quality, velo, nowTs);
    }

    /// @notice What the house signs for a swing (RSASSA-PKCS1-v1_5, SHA-256).
    function drawMessage(uint256 swingId) public view returns (bytes memory) {
        Swing storage s = swings[swingId];
        return abi.encode(DRAW_TAG, block.chainid, address(this), swingId, s.player, s.commit);
    }

    /// @notice Store the house draw for a committed swing. Anyone may send it, but only the
    ///         house key can sign it, and each swing has exactly one valid signature.
    function draw(uint256 swingId, bytes calldata sig) external {
        Swing storage s = swings[swingId];
        if (s.status != Status.Committed) revert WrongStatus();
        if (block.timestamp > uint256(s.committedAt) + DRAW_WINDOW) revert DrawClosed();
        if (!_drawValid(drawMessage(swingId), sig)) revert BadDraw();
        bytes32 h = keccak256(sig);
        s.status = Status.Drawn;
        s.drawHash = h;
        emit SwingDrawn(swingId, h);
    }

    function _drawValid(bytes memory message, bytes calldata sig) internal view virtual returns (bool) {
        return HouseDraw.verify(houseKey, message, sig);
    }

    /// @notice Reveal the salt once the house has drawn. Anyone holding the salt may call
    ///         it, but only the player has it. Too late and the swing counts as a foul.
    function finalize(uint256 swingId, bytes32 salt) external returns (uint8 tier, uint16 feet) {
        Swing storage s = swings[swingId];
        if (s.status != Status.Drawn) revert WrongStatus();
        if (commitFor(salt, s.player) != s.commit) revert BadSalt();

        s.status = Status.Final;
        if (block.timestamp > uint256(s.committedAt) + DRAW_WINDOW + REVEAL_WINDOW) {
            tier = DerbyOdds.FOUL;
        } else {
            (tier, feet) = DerbyOdds.roll(swingSeed(salt, s.drawHash), swingId, s.quality, s.velo);
        }

        if (tier >= DerbyOdds.HOMER) _recordDinger(s.league, s.day, s.player, feet);
        if (tier == DerbyOdds.SLAM) {
            uint256 payout = (vault[s.league] * SLAM_VAULT_SHARE_BPS) / 10_000;
            vault[s.league] -= payout;
            // Like settlement: if the token refuses the transfer, the prize stays in the
            // vault and the homer still counts.
            if (!_trySend(s.player, payout)) {
                vault[s.league] += payout;
                payout = 0;
            }
            emit GrandSlam(swingId, s.player, s.league, feet, payout);
        }
        emit SwingResolved(swingId, s.player, tier, feet);
    }

    /// @notice Close out a swing. Never drawn within DRAW_WINDOW: the turn (and the arcade
    ///         cap slot) comes back. Drawn but not revealed in time: a foul.
    function expire(uint256 swingId) external {
        Swing storage s = swings[swingId];
        uint256 committedAt = s.committedAt;
        if (s.status == Status.Committed) {
            if (block.timestamp <= committedAt + DRAW_WINDOW) revert NotExpired();
            s.status = Status.Refunded;
            turns[s.league][s.player] += 1;
            if (s.league == ARCADE) arcadeSwings[s.day][s.player] -= 1;
            emit SwingRefunded(swingId, s.player, s.league);
        } else if (s.status == Status.Drawn) {
            if (block.timestamp <= committedAt + DRAW_WINDOW + REVEAL_WINDOW) revert NotExpired();
            s.status = Status.Final;
            emit SwingResolved(swingId, s.player, DerbyOdds.FOUL, 0);
        } else {
            revert WrongStatus();
        }
    }

    function swingSeed(bytes32 salt, bytes32 drawHash) public pure returns (bytes32) {
        return keccak256(abi.encode(salt, drawHash));
    }

    /// @notice Preview the odds table for a quality (cumulative bps).
    function oddsFor(uint8 quality) external pure returns (uint256[5] memory) {
        return DerbyOdds.thresholds(quality);
    }

    // ───────── scoreboards ─────────

    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice A league's top players for a day, highest first. Arcade scores are longest
    ///         homers; agent scores are total homer feet.
    function board(uint8 league, uint256 day) external view returns (address[] memory players, uint256[] memory scores) {
        players = _board[league][day];
        scores = new uint256[](players.length);
        for (uint256 i; i < players.length; ++i) scores[i] = dayScore[league][day][players[i]];
    }

    function _recordDinger(uint8 league, uint256 day, address player, uint256 feet) internal {
        emit Dinger(player, league, day, feet);
        uint256 old = dayScore[league][day][player];
        uint256 score;
        if (league == ARCADE) {
            if (feet <= old) return; // not a new personal best that day
            score = feet;
        } else {
            score = old + feet;
        }
        dayScore[league][day][player] = score;
        _bump(league, day, player, score);
    }

    /// @dev Keep the day's board sorted, highest first. Ties keep the earlier score ahead.
    function _bump(uint8 league, uint256 day, address player, uint256 score) internal {
        address[] storage b = _board[league][day];
        mapping(address => uint256) storage sc = dayScore[league][day];
        uint256 n = b.length;
        uint256 i = n; // player's slot; n = not on the board
        for (uint256 k; k < n; ++k) {
            if (b[k] == player) { i = k; break; }
        }
        if (i == n) {
            if (n < BOARD_SIZE) {
                b.push(player);
            } else {
                if (score <= sc[b[n - 1]]) return;
                i = n - 1;
                b[i] = player;
            }
        }
        while (i > 0 && sc[b[i - 1]] < score) {
            b[i] = b[i - 1];
            b[i - 1] = player;
            --i;
        }
    }

    // ───────── daily settlement ─────────

    /// @notice True once `day` is over and none of its swings can still be drawn or revealed,
    ///         so its board is final.
    function dayClosed(uint8 league, uint256 day) public view returns (bool) {
        return day < currentDay()
            && block.timestamp > uint256(dayLastCommit[league][day]) + DRAW_WINDOW + REVEAL_WINDOW;
    }

    /// @notice The league's oldest unsettled day and what settling it now would pay.
    /// @return exists false when every day with activity is settled
    /// @return ready  dayClosed(league, day): settleNextDay would succeed
    /// @return day    the UTC day (timestamp / 1 days) settleNextDay pays next
    /// @return amount the day's pot plus rollover; 90% of it goes out when the board has players
    /// @return tip    what the caller would earn
    function nextSettlement(uint8 league)
        external
        view
        validLeague(league)
        returns (bool exists, bool ready, uint256 day, uint256 amount, uint256 tip)
    {
        uint256 i = settledDays[league];
        if (i >= _days[league].length) return (false, false, 0, 0, 0);
        day = _days[league][i];
        exists = true;
        ready = dayClosed(league, day);
        amount = dayPot[league][day] + rollover[league];
        if (_board[league][day].length > 0) tip = (amount * PAYOUT_BPS / 10_000) * SETTLE_TIP_BPS / 10_000;
    }

    /// @notice Pay a league's oldest unsettled day: its top 3 get 60 / 25 / 15 of 90% of the
    ///         day's pot plus rollover, after a 0.5% tip to the caller. Unfilled places, the
    ///         other 10% and any prize the token refuses to deliver roll over to the next day,
    ///         so one unpayable winner can't stop the queue. A day with no homers pays no tip.
    function settleNextDay(uint8 league) external validLeague(league) {
        uint256 i = settledDays[league];
        if (i >= _days[league].length) revert NothingToSettle();
        uint256 day = _days[league][i];
        if (!dayClosed(league, day)) revert DayNotOver();
        settledDays[league] = i + 1;

        uint256 amount = dayPot[league][day] + rollover[league];
        dayPot[league][day] = 0;
        address[] storage b = _board[league][day];
        uint256 n = b.length < 3 ? b.length : 3;
        address[] memory winners = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 tip;
        uint256 paid;
        if (n > 0) {
            uint256 distributable = (amount * PAYOUT_BPS) / 10_000;
            tip = (distributable * SETTLE_TIP_BPS) / 10_000;
            distributable -= tip;
            uint16[3] memory shares = [uint16(6000), 2500, 1500];
            paid = tip;
            for (uint256 k; k < n; ++k) {
                winners[k] = b[k];
                amounts[k] = (distributable * shares[k]) / 10_000;
                paid += amounts[k];
            }
        }
        rollover[league] = amount - paid;
        pot[league] -= paid;
        _send(msg.sender, tip);
        for (uint256 k; k < n; ++k) {
            if (!_trySend(winners[k], amounts[k])) {
                rollover[league] += amounts[k];
                pot[league] += amounts[k];
                amounts[k] = 0;
            }
        }
        emit DaySettled(league, day, winners, amounts, msg.sender, tip, rollover[league]);
    }

    /// @notice The league's days with activity that are not settled yet, oldest first.
    function openDays(uint8 league) external view validLeague(league) returns (uint256[] memory list) {
        uint256[] storage all = _days[league];
        uint256 start = settledDays[league];
        list = new uint256[](all.length - start);
        for (uint256 k; k < list.length; ++k) list[k] = all[start + k];
    }

    function _markDay(uint8 league, uint256 day) internal {
        uint256[] storage d = _days[league];
        if (d.length == 0 || d[d.length - 1] != day) d.push(day);
    }

    // ───────── admin (cannot touch pots or vaults; a house key change waits KEY_DELAY) ─────────

    /// @notice Prices apply to every later purchase. They can never go under
    ///         MIN_TURN_PRICE a turn, so turns never become free.
    function setPrices(uint256 single, uint256 pack) external onlyOwner {
        _checkPrices(single, pack);
        singlePrice = single;
        packPrice = pack;
    }

    /// @notice Propose a new house key. Anyone can activate it KEY_DELAY later. A new proposal
    ///         replaces the old one and restarts the delay.
    function proposeHouseKey(bytes calldata key) external onlyOwner {
        _checkKey(key);
        pendingHouseKey = key;
        pendingHouseKeyAt = block.timestamp + KEY_DELAY;
        emit HouseKeyProposed(keccak256(key), pendingHouseKeyAt);
    }

    function activateHouseKey() external {
        if (pendingHouseKeyAt == 0 || block.timestamp < pendingHouseKeyAt) revert KeyNotReady();
        houseKey = pendingHouseKey;
        delete pendingHouseKey;
        pendingHouseKeyAt = 0;
        emit HouseKeySet(keccak256(houseKey));
    }

    /// @notice Stop all draws at once (for a leaked key) and drop any proposal. Swings then
    ///         come back as refunds. Steering is impossible without a key; a new key needs KEY_DELAY.
    function revokeHouseKey() external onlyOwner {
        delete houseKey;
        delete pendingHouseKey;
        pendingHouseKeyAt = 0;
        emit HouseKeySet(bytes32(0));
    }

    /// @dev Shape only: 256 bytes, top bit set, odd. The contract can't check how the key was made.
    function _checkKey(bytes memory key) internal pure {
        if (key.length != HouseDraw.KEY_BYTES || uint8(key[0]) < 0x80 || uint8(key[key.length - 1]) & 1 == 0) {
            revert BadKey();
        }
    }

    function withdrawOps(address to, uint256 amount) external onlyOwner {
        opsBalance -= amount;
        _send(to, amount);
    }

    /// @notice Step 1 of an ownership move: name the new owner (address(0) cancels). Nothing
    ///         changes until that address calls acceptOwnership, so a typo can't lose the
    ///         ops share. There is no renounce: the owner can always withdraw ops.
    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    /// @notice Step 2: the named address takes over as owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ───────── internals ─────────

    function _checkPrices(uint256 single, uint256 pack) internal pure {
        if (single < MIN_TURN_PRICE || pack < MIN_TURN_PRICE * PACK_SIZE) revert BadPrice();
    }

    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }

    function _pull(address from, uint256 amount) internal {
        // A token address with no code (e.g. the other chain's IMD) accepts every call, so
        // refuse to credit a purchase until the token exists. Checked here, not in the
        // constructor, so deploy rehearsals without the token's code still work.
        if (address(imd).code.length == 0) revert NotAContract();
        (bool ok, bytes memory data) = address(imd).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (!_trySend(to, amount)) revert TransferFailed();
    }

    function _trySend(address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        (bool ok, bytes memory data) = address(imd).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (data.length == 0 || (data.length == 32 && abi.decode(data, (bool))));
    }
}
