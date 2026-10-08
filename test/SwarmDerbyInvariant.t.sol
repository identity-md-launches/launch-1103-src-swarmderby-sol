// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmDerby, IERC20} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";
import {HouseKeyTest} from "./HouseKey.sol";
import {MockIMD} from "./SwarmDerby.t.sol";

/// Uses the actual application and RSA verification, with the existing public test key.
/// Ghosts come from requested purchases, swing outcomes and external token movements.
contract DerbySequenceHandler is HouseKeyTest {
    SwarmDerby public immutable derby;
    MockIMD public immutable imd;
    address[4] public players;
    address[4] public sessions;
    address public immutable keeper;
    address public immutable opsRecipient;
    uint256 public constant INITIAL_BALANCE = 1_000_000 ether;

    uint256 public purchased;
    uint256 public donated;
    uint256 public paidOut;
    uint256 public opsWithdrawn;
    uint256 public resolved;
    uint256 public refunded;
    uint256 public settlements;
    uint256 public failedPayments;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public received;
    mapping(uint8 => mapping(address => uint256)) public boughtTurns;
    mapping(uint8 => mapping(address => uint256)) public spentTurns;
    mapping(uint256 => bytes32) public salts;
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) public scores;
    mapping(uint8 => mapping(uint256 => bool)) public settled;
    mapping(uint8 => mapping(uint256 => bytes32)) public closedBoards;
    mapping(uint8 => uint256[]) internal activeDays;
    mapping(uint8 => mapping(uint256 => bool)) internal knownDay;

    constructor(SwarmDerby derby_, MockIMD imd_) {
        derby = derby_;
        imd = imd_;
        keeper = makeAddr("invariant keeper");
        opsRecipient = makeAddr("invariant ops recipient");
        for (uint256 i; i < players.length; ++i) {
            players[i] = makeAddr(string.concat("invariant player ", vm.toString(i)));
            sessions[i] = vm.addr(0x5E55 + i);
            _fund(players[i]);
            _fund(sessions[i]);
        }
    }

    function _fund(address actor) internal {
        imd.mint(actor, INITIAL_BALANCE);
        vm.prank(actor);
        imd.approve(address(derby), type(uint256).max);
    }

    function daysFor(uint8 league) external view returns (uint256[] memory) {
        return activeDays[league];
    }

    function _rememberDay(uint8 league, uint256 day) internal {
        if (!knownDay[league][day]) {
            knownDay[league][day] = true;
            activeDays[league].push(day);
        }
    }

    function _caller(uint256 actor, bool viaSession) internal view returns (address) {
        return viaSession && derby.sessionOf(players[actor]) == sessions[actor] ? sessions[actor] : players[actor];
    }

    function buy(uint256 actorSeed, uint8 leagueSeed, uint256 countSeed, bool packs, bool viaSession) public {
        uint256 actor = actorSeed % players.length;
        uint8 league = leagueSeed % 2;
        uint256 count = bound(countSeed, 1, 20);
        address payer = _caller(actor, viaSession);
        uint256 cost = count * (packs ? derby.packPrice() : derby.singlePrice());
        vm.prank(payer);
        if (packs) derby.buyPacks(league, count);
        else derby.buyTurns(league, count);
        spent[payer] += cost;
        purchased += cost;
        boughtTurns[league][players[actor]] += count * (packs ? 5 : 1);
        _rememberDay(league, derby.currentDay());
    }

    function play(uint256 actorSeed, uint8 leagueSeed, uint8 qualitySeed, uint8 veloSeed, bool finish, bool viaSession)
        external
    {
        uint256 actor = actorSeed % players.length;
        uint8 league = leagueSeed % 2;
        address player = players[actor];
        if (derby.turns(league, player) == 0) buy(actor, league, 1, false, viaSession);
        uint8 quality = uint8(bound(qualitySeed, 0, 100));
        uint8 velo = uint8(bound(veloSeed, 0, 100));
        bytes32 salt = keccak256(abi.encode("sequence salt", derby.nextSwingId(), player));
        bytes32 commitment = derby.commitFor(salt, player);
        if (league == 0 && derby.arcadeSwingsLeft(player) == 0) {
            vm.prank(_caller(actor, viaSession));
            vm.expectRevert(SwarmDerby.DailyCapReached.selector);
            derby.swing(league, quality, velo, commitment);
            return;
        }
        vm.prank(_caller(actor, viaSession));
        uint256 id = derby.swing(league, quality, velo, commitment);
        salts[id] = salt;
        ++spentTurns[league][player];
        _rememberDay(league, derby.currentDay());
        if (quality == 0) {
            ++resolved;
        } else if (finish) {
            derby.draw(id, _houseSign(derby.drawMessage(id)));
            _finalize(id, false);
        }
    }

    function draw(uint256 seed) external {
        if (derby.nextSwingId() == 0) return;
        uint256 id = seed % derby.nextSwingId();
        (,,,, SwarmDerby.Status status, uint64 at,,,) = derby.swings(id);
        bytes memory sig = _houseSign(derby.drawMessage(id));
        if (status != SwarmDerby.Status.Committed) {
            vm.expectRevert(SwarmDerby.WrongStatus.selector);
        } else if (block.timestamp > uint256(at) + 5 minutes) {
            vm.expectRevert(SwarmDerby.DrawClosed.selector);
        }
        derby.draw(id, sig);
    }

    function finalize(uint256 seed, bool rejectPayment) external {
        if (derby.nextSwingId() == 0) return;
        uint256 id = seed % derby.nextSwingId();
        (,,,, SwarmDerby.Status status,,,,) = derby.swings(id);
        if (status != SwarmDerby.Status.Drawn) {
            vm.expectRevert(SwarmDerby.WrongStatus.selector);
            derby.finalize(id, salts[id]);
            return;
        }
        _finalize(id, rejectPayment);
    }

    function _finalize(uint256 id, bool rejectPayment) internal {
        (address player, uint8 league,,,,,, uint32 day,) = derby.swings(id);
        uint256 balanceBefore = imd.balanceOf(player);
        if (rejectPayment) _refuse(player);
        (uint8 tier, uint16 feet) = derby.finalize(id, salts[id]);
        vm.clearMockedCalls();
        uint256 payment = imd.balanceOf(player) - balanceBefore;
        received[player] += payment;
        paidOut += payment;
        ++resolved;
        if (rejectPayment && tier == DerbyOdds.SLAM) ++failedPayments;
        if (tier >= DerbyOdds.HOMER) {
            if (league == 0) {
                if (feet > scores[league][day][player]) scores[league][day][player] = feet;
            } else {
                scores[league][day][player] += feet;
            }
        }
    }

    function expire(uint256 seed) external {
        if (derby.nextSwingId() == 0) return;
        uint256 id = seed % derby.nextSwingId();
        (address player, uint8 league,,, SwarmDerby.Status status, uint64 at,,,) = derby.swings(id);
        if (status == SwarmDerby.Status.Committed || status == SwarmDerby.Status.Drawn) {
            uint256 window = status == SwarmDerby.Status.Committed ? 5 minutes : 10 minutes;
            if (block.timestamp <= uint256(at) + window) {
                vm.expectRevert(SwarmDerby.NotExpired.selector);
                derby.expire(id);
                return;
            }
            derby.expire(id);
            if (status == SwarmDerby.Status.Committed) {
                --spentTurns[league][player];
                ++refunded;
            } else {
                ++resolved;
            }
        } else {
            vm.expectRevert(SwarmDerby.WrongStatus.selector);
            derby.expire(id);
        }
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 2 days));
    }

    function settle(uint8 leagueSeed, uint256 refusedActorSeed, bool rejectPayment) external {
        uint8 league = leagueSeed % 2;
        (bool exists, bool ready, uint256 day,,) = derby.nextSettlement(league);
        if (!exists || !ready) {
            vm.expectRevert(exists ? SwarmDerby.DayNotOver.selector : SwarmDerby.NothingToSettle.selector);
            derby.settleNextDay(league);
            return;
        }
        uint256[4] memory beforeBalances;
        for (uint256 i; i < players.length; ++i) {
            beforeBalances[i] = imd.balanceOf(players[i]);
        }
        uint256 keeperBefore = imd.balanceOf(keeper);
        if (rejectPayment) _refuse(players[refusedActorSeed % players.length]);
        vm.prank(keeper);
        derby.settleNextDay(league);
        vm.clearMockedCalls();
        for (uint256 i; i < players.length; ++i) {
            uint256 payment = imd.balanceOf(players[i]) - beforeBalances[i];
            received[players[i]] += payment;
            paidOut += payment;
        }
        paidOut += imd.balanceOf(keeper) - keeperBefore;
        assertFalse(settled[league][day], "day paid twice");
        settled[league][day] = true;
        (address[] memory board, uint256[] memory values) = derby.board(league, day);
        closedBoards[league][day] = keccak256(abi.encode(board, values));
        ++settlements;
    }

    function _refuse(address recipient) internal {
        // The token returns malformed bool 2 without moving funds, like the existing MockIMD.odd_ path.
        vm.mockCall(address(imd), abi.encodeWithSelector(IERC20.transfer.selector, recipient), abi.encode(uint256(2)));
    }

    function withdraw(uint256 amountSeed, bool rejectPayment) external {
        uint256 amount = bound(amountSeed, 0, derby.opsBalance());
        if (rejectPayment && amount > 0) {
            _refuse(opsRecipient);
            uint256 beforeOps = derby.opsBalance();
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.withdrawOps(opsRecipient, amount);
            vm.clearMockedCalls();
            assertEq(derby.opsBalance(), beforeOps, "failed withdrawal consumed ops");
            ++failedPayments;
        } else {
            derby.withdrawOps(opsRecipient, amount);
            opsWithdrawn += amount;
        }
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external {
        address actor = players[actorSeed % players.length];
        uint256 amount = bound(amountSeed, 0, 1 ether);
        vm.prank(actor);
        imd.transfer(address(derby), amount);
        donated += amount;
        spent[actor] += amount;
    }

    function prices(uint256 singleSeed, uint256 packSeed) external {
        // Include non-round prices to expose accumulated rounding dust.
        derby.setPrices(bound(singleSeed, 0.01 ether, 1 ether), bound(packSeed, 0.05 ether, 5 ether));
    }

    function session(uint256 actorSeed, uint8 action) external {
        uint256 actor = actorSeed % players.length;
        address player = players[actor];
        address key = sessions[actor];
        if (derby.sessionOf(player) != address(0)) {
            if (action % 2 == 0) {
                vm.prank(key);
                derby.leaveSession();
            } else {
                vm.prank(player);
                derby.setSession(address(0), "");
            }
        } else {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x5E55 + actor, derby.sessionDigest(player, key));
            vm.prank(player);
            derby.setSession(key, abi.encodePacked(r, s, v));
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmDerbyInvariantTest is HouseKeyTest {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    SwarmDerby internal derby;
    MockIMD internal imd;
    DerbySequenceHandler internal handler;

    function setUp() public {
        vm.warp(20_370 days + 1 hours);
        // Offline dependency behavior only. No token constructor or extra application is deployed.
        vm.etch(IMD, type(MockIMD).runtimeCode);
        imd = MockIMD(IMD);
        derby = _deployDerby(address(this), IERC20(IMD), 0.15 ether, 0.5 ether, _houseKey());
        handler = new DerbySequenceHandler(derby, imd);
        derby.transferOwnership(address(handler));
        vm.prank(address(handler));
        derby.acceptOwnership();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.play.selector;
        selectors[2] = handler.draw.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.expire.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.withdraw.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.prices.selector;
        selectors[10] = handler.session.selector;
        // Weight swings to reach more real draws, scoring outcomes and payouts.
        selectors[11] = handler.play.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        // Both leagues begin with funds and pending draws; failures cannot hide behind an empty system.
        handler.buy(0, 0, 5, true, false);
        handler.buy(1, 1, 5, true, false);
        handler.play(0, 0, 100, 100, false, false);
        handler.play(1, 1, 100, 100, false, false);
    }

    function test_handlerSequenceReachesPayoutRefundAndRejectedWithdrawal() public {
        handler.session(0, 0);
        handler.buy(0, 1, 5, true, true);
        uint256 day = derby.currentDay();
        address player = handler.players(0);
        for (uint256 i; i < 32 && derby.dayScore(1, day, player) == 0; ++i) {
            handler.play(0, 1, 100, 100, true, true);
        }
        assertGt(derby.dayScore(1, day, player), 0, "handler never reached a scoring outcome");
        handler.withdraw(1, true);
        handler.advance(1 days);
        handler.expire(0);
        handler.expire(1);
        handler.settle(0, 0, false);
        handler.settle(1, 0, false);
        handler.donate(0, 1);
        handler.withdraw(derby.opsBalance(), false);
        assertGt(handler.paidOut(), 0, "handler never paid a prize");
        assertGt(handler.resolved(), 0);
        assertEq(handler.refunded(), 2);
        assertEq(handler.settlements(), 2);
        assertEq(handler.failedPayments(), 1);
        invariant_tokenBackingAndConservation();
        invariant_potsEqualOpenDaysAndRollover();
        invariant_turnsCapsAndTerminalStates();
        invariant_scoresBoardsAndSessions();
    }

    function invariant_tokenBackingAndConservation() public view {
        uint256 liabilities = derby.opsBalance();
        for (uint8 league; league < 2; ++league) {
            liabilities += derby.pot(league) + derby.vault(league);
        }
        uint256 held = imd.balanceOf(address(derby));
        assertEq(held, liabilities + handler.donated(), "liabilities lost token backing");
        assertEq(
            handler.purchased() + handler.donated(),
            held + imd.balanceOf(derby.DEAD()) + handler.paidOut() + handler.opsWithdrawn(),
            "tokens created or lost across payments"
        );
        assertEq(imd.balanceOf(handler.opsRecipient()), handler.opsWithdrawn());
        for (uint256 i; i < 4; ++i) {
            address player = handler.players(i);
            address key = handler.sessions(i);
            assertEq(
                imd.balanceOf(player) + handler.spent(player),
                handler.INITIAL_BALANCE() + handler.received(player),
                "player wallet disagrees with ghost ledger"
            );
            assertEq(imd.balanceOf(key) + handler.spent(key), handler.INITIAL_BALANCE(), "session received a prize");
        }
    }

    function invariant_potsEqualOpenDaysAndRollover() public view {
        for (uint8 league; league < 2; ++league) {
            uint256[] memory open = derby.openDays(league);
            uint256 sum = derby.rollover(league);
            for (uint256 i; i < open.length; ++i) {
                if (i > 0) assertGt(open[i], open[i - 1], "queue must be strictly ordered");
                assertFalse(handler.settled(league, open[i]), "settled day reopened");
                sum += derby.dayPot(league, open[i]);
            }
            assertEq(derby.pot(league), sum, "pot differs from its obligations");
            uint256[] memory activity = handler.daysFor(league);
            for (uint256 i; i < activity.length; ++i) {
                if (handler.settled(league, activity[i])) {
                    assertEq(derby.dayPot(league, activity[i]), 0);
                    (address[] memory board, uint256[] memory scores) = derby.board(league, activity[i]);
                    assertEq(keccak256(abi.encode(board, scores)), handler.closedBoards(league, activity[i]));
                }
            }
        }
        assertEq(derby.settledDays(0) + derby.settledDays(1), handler.settlements());
    }

    function invariant_turnsCapsAndTerminalStates() public view {
        uint256 terminal;
        uint256 refunds;
        for (uint256 id; id < derby.nextSwingId(); ++id) {
            (address player, uint8 league, uint8 quality,, SwarmDerby.Status status,, bytes32 commit,,) =
                derby.swings(id);
            if (quality > 0) assertTrue(derby.commitUsed(player, commit), "commit became reusable");
            if (status == SwarmDerby.Status.Final) ++terminal;
            if (status == SwarmDerby.Status.Refunded) ++refunds;
            assertLt(league, 2);
        }
        assertEq(terminal, handler.resolved(), "terminal swing reopened or resolved twice");
        assertEq(refunds, handler.refunded(), "refund status changed");
        for (uint256 i; i < 4; ++i) {
            address player = handler.players(i);
            for (uint8 league; league < 2; ++league) {
                assertEq(
                    derby.turns(league, player) + handler.spentTurns(league, player),
                    handler.boughtTurns(league, player),
                    "turn created or destroyed"
                );
            }
            uint256[] memory activity = handler.daysFor(0);
            for (uint256 d; d < activity.length; ++d) {
                uint256 used;
                for (uint256 id; id < derby.nextSwingId(); ++id) {
                    (address who, uint8 league,,, SwarmDerby.Status status,,, uint32 day,) = derby.swings(id);
                    if (who == player && league == 0 && day == activity[d] && status != SwarmDerby.Status.Refunded) {
                        ++used;
                    }
                }
                assertEq(derby.arcadeSwings(activity[d], player), used, "cap slot refunded on wrong day");
                assertLe(used, 20, "arcade cap exceeded");
            }
        }
    }

    function invariant_scoresBoardsAndSessions() public view {
        for (uint256 actor; actor < 4; ++actor) {
            address player = handler.players(actor);
            address key = handler.sessions(actor);
            if (derby.sessionOf(player) == key) {
                assertEq(derby.sessionPlayer(key), player);
                assertEq(derby.playerOf(key), player);
            } else {
                assertEq(derby.sessionPlayer(key), address(0));
                assertEq(derby.playerOf(key), key);
            }
        }
        for (uint8 league; league < 2; ++league) {
            uint256[] memory activity = handler.daysFor(league);
            for (uint256 d; d < activity.length; ++d) {
                (address[] memory board, uint256[] memory values) = derby.board(league, activity[d]);
                assertLe(board.length, 4);
                for (uint256 i; i < board.length; ++i) {
                    assertGt(values[i], 0);
                    if (i > 0) assertGe(values[i - 1], values[i]);
                    for (uint256 j; j < i; ++j) {
                        assertNotEq(board[i], board[j]);
                    }
                }
                uint256 scorers;
                for (uint256 i; i < 4; ++i) {
                    address player = handler.players(i);
                    uint256 score = handler.scores(league, activity[d], player);
                    assertEq(
                        derby.dayScore(league, activity[d], player), score, "score credited to wrong player or day"
                    );
                    if (score > 0) {
                        ++scorers;
                        bool listed;
                        for (uint256 j; j < board.length; ++j) {
                            if (board[j] == player) {
                                listed = true;
                                assertEq(values[j], score);
                            }
                        }
                        assertTrue(listed, "scorer missing from board");
                    }
                }
                assertEq(board.length, scorers);
            }
        }
    }
}
