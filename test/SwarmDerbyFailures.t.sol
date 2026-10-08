// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmDerby, IERC20} from "src/SwarmDerby.sol";
import {DerbyOdds} from "src/DerbyOdds.sol";
import {HouseKeyTest} from "./HouseKey.sol";
import {MockIMD} from "./SwarmDerby.t.sol";

contract SwarmDerbyFailuresTest is HouseKeyTest {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 constant DAY = 20_370;
    uint256 constant T0 = DAY * 1 days + 1 hours;
    SwarmDerby internal derby;
    MockIMD internal imd;
    address internal player;
    address internal other;

    function setUp() public {
        vm.warp(T0);
        player = makeAddr("failure path player");
        other = makeAddr("failure path other player");
        // Reuse the accepted offline dependency behavior, without deploying a token fixture.
        vm.etch(IMD, type(MockIMD).runtimeCode);
        imd = MockIMD(IMD);
        derby = _deployDerby(address(this), IERC20(IMD), 0.15 ether, 0.5 ether, _houseKey());
        imd.mint(player, 1_000_000 ether);
        imd.mint(other, 1_000_000 ether);
        vm.prank(player);
        imd.approve(address(derby), type(uint256).max);
        vm.prank(other);
        imd.approve(address(derby), type(uint256).max);
    }

    function _buy(address who, uint8 league, uint256 count) internal {
        vm.prank(who);
        derby.buyTurns(league, count);
    }

    function _commit(address who, uint8 league, bytes32 salt) internal returns (uint256 id) {
        bytes32 commitment = derby.commitFor(salt, who);
        vm.prank(who);
        id = derby.swing(league, 100, 100, commitment);
    }

    function _moneyState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                derby.pot(0),
                derby.pot(1),
                derby.vault(0),
                derby.vault(1),
                derby.opsBalance(),
                derby.dayPot(0, DAY),
                derby.dayPot(1, DAY),
                derby.rollover(0),
                derby.rollover(1),
                derby.turns(0, player),
                derby.turns(1, player),
                derby.openDays(0),
                derby.openDays(1),
                derby.settledDays(0),
                derby.settledDays(1),
                imd.balanceOf(player),
                imd.balanceOf(other),
                imd.balanceOf(address(derby)),
                imd.balanceOf(derby.DEAD()),
                imd.balanceOf(address(this)),
                imd.allowance(player, address(derby))
            )
        );
    }

    function _backed() internal view {
        assertEq(
            imd.balanceOf(address(derby)),
            derby.pot(0) + derby.pot(1) + derby.vault(0) + derby.vault(1) + derby.opsBalance()
        );
    }

    /// A real signed swing producing a homer, without writing the board or bypassing RSA.
    function _score(address who, uint8 league) internal {
        _buy(who, league, 32);
        for (uint256 i; i < 32; ++i) {
            bytes32 salt = keccak256(abi.encode("score", who, i));
            uint256 id = _commit(who, league, salt);
            derby.draw(id, _houseSign(derby.drawMessage(id)));
            (uint8 tier,) = derby.finalize(id, salt);
            if (tier >= DerbyOdds.HOMER) return;
        }
        fail("fixture did not generate a scoring swing");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_purchaseSplitConservesEveryWei(uint256 priceSeed, uint256 countSeed, bool packs, bool agent)
        public
    {
        uint256 unitPrice = bound(priceSeed, 0.05 ether, 5 ether);
        uint256 count = bound(countSeed, 1, 100);
        uint8 league = agent ? 1 : 0;
        derby.setPrices(unitPrice, unitPrice);
        uint256 beforeBalance = imd.balanceOf(player);
        vm.prank(player);
        if (packs) derby.buyPacks(league, count);
        else derby.buyTurns(league, count);
        uint256 cost = unitPrice * count;
        assertEq(beforeBalance - imd.balanceOf(player), cost);
        assertEq(derby.turns(league, player), count * (packs ? 5 : 1));
        assertEq(imd.balanceOf(address(derby)) + imd.balanceOf(derby.DEAD()), cost);
        // Ratio bounds capture floor rounding independently of the implementation's divisions.
        uint256 burnError = cost * 4000 - imd.balanceOf(derby.DEAD()) * 10_000;
        uint256 potError = cost * 4500 - derby.pot(league) * 10_000;
        uint256 vaultError = cost * 1000 - derby.vault(league) * 10_000;
        assertLt(burnError, 10_000);
        assertLt(potError, 10_000);
        assertLt(vaultError, 10_000);
        assertEq(derby.opsBalance() * 10_000, cost * 500 + burnError + potError + vaultError);
        assertEq(derby.pot(1 - league), 0);
        assertEq(derby.vault(1 - league), 0);
        _backed();
    }

    function test_falseOrRevertingPullRollsBackAllPurchaseEffects() public {
        _buy(player, 0, 1);
        bytes32 beforeState = _moneyState();
        for (uint256 i; i < 2; ++i) {
            if (i == 0) vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false));
            else vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transferFrom.selector), "paused");
            vm.prank(player);
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.buyPacks(1, 2);
            vm.clearMockedCalls();
            assertEq(_moneyState(), beforeState);
        }
    }

    function test_malformedPullCannotCreditUnbackedTurns() public {
        bytes[3] memory replies = [abi.encode(uint256(2)), bytes(hex"01"), new bytes(31)];
        bytes32 beforeState = _moneyState();
        for (uint256 i; i < replies.length; ++i) {
            vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transferFrom.selector), replies[i]);
            vm.prank(player);
            // ABI decoding malformed bools/short words has no application error selector.
            vm.expectRevert();
            derby.buyTurns(0, 1);
            vm.clearMockedCalls();
            assertEq(_moneyState(), beforeState);
        }
    }

    function test_rejectedBurnRollsBackSuccessfulPullAndAllowance() public {
        _buy(player, 1, 1);
        bytes[4] memory replies = [abi.encode(false), abi.encode(uint256(2)), bytes(hex"01"), abi.encode(true, true)];
        bytes32 beforeState = _moneyState();
        for (uint256 i; i < replies.length; ++i) {
            vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, derby.DEAD()), replies[i]);
            vm.prank(player);
            vm.expectRevert(SwarmDerby.TransferFailed.selector);
            derby.buyPacks(0, 1);
            vm.clearMockedCalls();
            assertEq(_moneyState(), beforeState);
        }
    }

    function test_purchaseWithoutAllowanceCannotChangeQueueOrMoney() public {
        vm.prank(player);
        imd.approve(address(derby), 0.15 ether - 1);
        bytes32 beforeState = _moneyState();
        vm.prank(player);
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.buyTurns(1, 1);
        assertEq(_moneyState(), beforeState);
    }

    function test_maximumPurchaseCountsRevertWithoutEffects() public {
        bytes32 beforeState = _moneyState();
        vm.startPrank(player);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        derby.buyTurns(0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        derby.buyPacks(1, type(uint256).max);
        vm.stopPrank();
        assertEq(_moneyState(), beforeState);
    }

    function test_rejectedOpsWithdrawalRestoresBalance() public {
        _buy(player, 0, 10);
        imd.odd_(other);
        uint256 amount = derby.opsBalance();
        bytes32 beforeState = _moneyState();
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.withdrawOps(other, amount);
        assertEq(_moneyState(), beforeState);
        derby.withdrawOps(player, amount);
        assertEq(derby.opsBalance(), 0);
        _backed();
    }

    function test_allAdminFunctionsRejectPlayer() public {
        _buy(player, 0, 10);
        derby.proposeHouseKey(_houseKey());
        bytes32 beforeState = _moneyState();
        uint256 activeAt = derby.pendingHouseKeyAt();
        vm.startPrank(player);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(0.2 ether, 0.6 ether);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.proposeHouseKey(_houseKey());
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.cancelHouseKey();
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.revokeHouseKey();
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.withdrawOps(player, 1);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.transferOwnership(player);
        vm.stopPrank();
        assertEq(_moneyState(), beforeState);
        assertEq(derby.owner(), address(this));
        assertEq(derby.pendingOwner(), address(0));
        assertEq(derby.pendingHouseKeyAt(), activeAt);
        assertEq(derby.houseKey(), _houseKey());
        assertEq(derby.singlePrice(), 0.15 ether);
        assertEq(derby.packPrice(), 0.5 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allLeagueValidatedEntrypointsRejectInvalidLeague(uint8 seed) public {
        uint8 league = uint8(bound(seed, 2, 255));
        bytes32 beforeState = _moneyState();
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyTurns(league, 1);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.buyPacks(league, 1);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.swing(league, 100, 100, bytes32(uint256(1)));
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.settleNextDay(league);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.openDays(league);
        vm.expectRevert(SwarmDerby.BadLeague.selector);
        derby.nextSettlement(league);
        assertEq(_moneyState(), beforeState);
    }

    function test_failedSettlerTipRollsBackQueueThenDifferentCallerCanSettle() public {
        _score(player, 1);
        vm.warp((DAY + 1) * 1 days);
        bytes32 beforeState = _moneyState();
        imd.block_(address(this));
        vm.expectRevert(SwarmDerby.TransferFailed.selector);
        derby.settleNextDay(1);
        assertEq(_moneyState(), beforeState);
        (,,,, uint256 tip) = derby.nextSettlement(1);
        assertGt(tip, 0);
        uint256 beforeBalance = imd.balanceOf(other);
        vm.prank(other);
        derby.settleNextDay(1);
        assertEq(imd.balanceOf(other) - beforeBalance, tip);
        assertEq(derby.settledDays(1), 1);
        _backed();
    }

    function test_malformedWinnerPaymentsRollOverAndOtherWinnerIsPaid() public {
        _score(player, 1);
        _score(other, 1);
        vm.warp((DAY + 1) * 1 days);
        uint256 originalPot = derby.pot(1);
        uint256 playerBefore = imd.balanceOf(player);
        uint256 otherBefore = imd.balanceOf(other);
        bytes[4] memory replies = [abi.encode(false), abi.encode(uint256(2)), bytes(hex"01"), abi.encode(true, true)];
        for (uint256 i; i < replies.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, player), replies[i]);
            derby.settleNextDay(1);
            vm.clearMockedCalls();
            assertEq(imd.balanceOf(player), playerBefore);
            uint256 otherPaid = imd.balanceOf(other) - otherBefore;
            assertGt(otherPaid, 0);
            assertEq(derby.pot(1), originalPot - otherPaid - imd.balanceOf(address(this)));
            assertEq(derby.rollover(1), derby.pot(1));
            assertEq(derby.openDays(1).length, 0);
            _backed();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_refundedCommitCannotBeReusedInEitherLeague() public {
        _buy(player, 0, 2);
        _buy(player, 1, 2);
        bytes32 salt = keccak256("single use even after refund");
        uint256 id = _commit(player, 0, salt);
        vm.warp(T0 + 5 minutes + 1);
        derby.expire(id);
        bytes32 commitment = derby.commitFor(salt, player);
        bytes32 beforeState = _moneyState();
        for (uint8 league; league < 2; ++league) {
            vm.prank(player);
            vm.expectRevert(SwarmDerby.CommitUsed.selector);
            derby.swing(league, 100, 100, commitment);
        }
        assertEq(_moneyState(), beforeState);
        assertEq(derby.nextSwingId(), 1);
        assertEq(derby.arcadeSwings(DAY, player), 0);
    }

    function test_previousDayRefundDoesNotFreeTodaysCapSlot() public {
        _buy(player, 0, 3);
        vm.warp((DAY + 1) * 1 days - 1);
        uint256 yesterday = _commit(player, 0, keccak256("yesterday"));
        vm.warp((DAY + 1) * 1 days + 5 minutes);
        _commit(player, 0, keccak256("today"));
        derby.expire(yesterday);
        assertEq(derby.arcadeSwings(DAY, player), 0);
        assertEq(derby.arcadeSwings(DAY + 1, player), 1);
        assertEq(derby.arcadeSwingsLeft(player), 19);
        assertEq(derby.turns(0, player), 2);
    }

    function test_drawAtExactDeadlineSucceedsAndCannotThenRefund() public {
        _buy(player, 0, 1);
        bytes32 salt = keccak256("draw boundary");
        uint256 id = _commit(player, 0, salt);
        bytes memory sig = _houseSign(derby.drawMessage(id));
        vm.warp(T0 + 5 minutes);
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id);
        derby.draw(id, sig);
        vm.warp(T0 + 10 minutes);
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id);
        derby.finalize(id, salt);
        assertEq(derby.turns(0, player), 0);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, salt);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(id);
    }

    function test_houseDrawSignatureCannotReplayAcrossChains() public {
        _buy(player, 0, 1);
        uint256 id = _commit(player, 0, keccak256("chain bound draw"));
        bytes memory sig = _houseSign(derby.drawMessage(id));
        // Read through the cheatcode so via-IR cannot rematerialize CHAINID after the change.
        uint256 originalChain = vm.getChainId();
        vm.chainId(originalChain + 1);
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(id, sig);
        vm.chainId(originalChain);
        derby.draw(id, sig);
    }

    function test_replacingKeyProposalRestartsDelayAndRevokeCancelsIt() public {
        derby.proposeHouseKey(_houseKey());
        uint256 originalActivation = derby.pendingHouseKeyAt();
        vm.warp(originalActivation - 1);
        derby.proposeHouseKey(_houseKey());
        uint256 replacementActivation = derby.pendingHouseKeyAt();
        assertEq(replacementActivation, originalActivation - 1 + 2 days);
        vm.warp(originalActivation);
        vm.expectRevert(SwarmDerby.KeyNotReady.selector);
        derby.activateHouseKey();
        derby.revokeHouseKey();
        vm.warp(replacementActivation);
        vm.expectRevert(SwarmDerby.KeyNotReady.selector);
        derby.activateHouseKey();
        assertEq(derby.houseKey().length, 0);
        assertEq(derby.pendingHouseKey().length, 0);
        assertEq(derby.pendingHouseKeyAt(), 0);
    }

    function test_sessionSignatureDomainAndFailedRotationPreserveOldSession() public {
        uint256 oldPk = 0x5E55;
        uint256 newPk = 0x5E56;
        address oldKey = vm.addr(oldPk);
        address newKey = vm.addr(newPk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oldPk, derby.sessionDigest(player, oldKey));
        vm.prank(player);
        derby.setSession(oldKey, abi.encodePacked(r, s, v));
        (v, r, s) = vm.sign(newPk, derby.sessionDigest(player, newKey));
        bytes memory consent = abi.encodePacked(r, s, v);
        uint256 originalChain = vm.getChainId();
        vm.chainId(originalChain + 1);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.BadSession.selector);
        derby.setSession(newKey, consent);
        assertEq(derby.sessionOf(player), oldKey);
        assertEq(derby.sessionPlayer(oldKey), player);
        assertEq(derby.sessionNonce(newKey), 0);
        vm.chainId(originalChain);
        vm.prank(player);
        derby.setSession(newKey, consent);
        assertEq(derby.sessionPlayer(oldKey), address(0));
        assertEq(derby.sessionPlayer(newKey), player);
        assertEq(derby.sessionNonce(newKey), 1);
    }

    function test_malformedSessionSignaturesCannotBind() public {
        address key = vm.addr(0x5E55);
        bytes[4] memory signatures = [
            new bytes(64),
            new bytes(66),
            abi.encodePacked(bytes32(uint256(1)), bytes32(type(uint256).max), uint8(27)),
            abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1)), uint8(29))
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(player);
            vm.expectRevert(SwarmDerby.BadSession.selector);
            derby.setSession(key, signatures[i]);
            assertEq(derby.sessionOf(player), address(0));
            assertEq(derby.sessionPlayer(key), address(0));
            assertEq(derby.sessionNonce(key), 0);
        }
    }
}
