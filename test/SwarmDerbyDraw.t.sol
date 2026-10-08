// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmDerby, IERC20} from "../src/SwarmDerby.sol";
import {DerbyOdds} from "../src/DerbyOdds.sol";
import {HouseKeyTest} from "./HouseKey.sol";
import {MockIMD} from "./SwarmDerby.t.sol";

/// SwarmDerby with the real signature check and the test house key.
contract SwarmDerbyDrawTest is HouseKeyTest {
    MockIMD imd;
    SwarmDerby derby;
    address player = address(0xBA77E2);
    bytes32 constant SALT = keccak256("player-salt");
    uint256 constant T0 = 20_370 * 1 days + 1 hours;

    function setUp() public {
        vm.warp(T0);
        imd = new MockIMD();
        derby = _deployDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether, _houseKey());
        imd.mint(player, 100 ether);
        vm.startPrank(player);
        imd.approve(address(derby), type(uint256).max);
        derby.buyTurns(0, 5);
        derby.buyTurns(1, 5);
        vm.stopPrank();
    }

    function _commit(uint8 league, bytes32 salt) internal returns (uint256 id) {
        bytes32 c = derby.commitFor(salt, player);
        vm.prank(player);
        id = derby.swing(league, 100, 100, c);
    }

    function _sign(uint256 id) internal returns (bytes memory) {
        return _houseSign(derby.drawMessage(id));
    }

    function test_realDrawFullSwing() public {
        uint256 id = _commit(0, SALT);
        bytes memory sig = _sign(id);
        vm.expectEmit(true, false, false, true, address(derby));
        emit SwarmDerby.SwingDrawn(id, keccak256(sig));
        derby.draw(id, sig);
        (uint8 tier, uint16 feet) = derby.finalize(id, SALT);
        (uint8 eTier, uint16 eFeet) = DerbyOdds.roll(derby.swingSeed(SALT, keccak256(sig)), id, 100, 100);
        assertEq(tier, eTier);
        assertEq(feet, eFeet);
    }

    function test_drawForAnotherSwingRejected() public {
        uint256 a = _commit(0, SALT);
        uint256 b = _commit(0, keccak256("second salt"));
        bytes memory sigA = _sign(a);
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(b, sigA);
        derby.draw(a, sigA);
    }

    function test_drawFromAnotherDeploymentRejected() public {
        SwarmDerby other = _deployDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether, _houseKey());
        vm.startPrank(player);
        imd.approve(address(other), type(uint256).max);
        other.buyTurns(0, 1);
        uint256 idOther = other.swing(0, 100, 100, other.commitFor(SALT, player));
        vm.stopPrank();
        uint256 id = _commit(0, SALT);
        assertEq(id, idOther);
        bytes memory sigOther = _houseSign(other.drawMessage(idOther));
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(id, sigOther);
    }

    function test_tamperedDrawRejected() public {
        uint256 id = _commit(0, SALT);
        bytes memory sig = _sign(id);
        sig[17] = bytes1(uint8(sig[17]) ^ 0x40);
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(id, sig);
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(id, new bytes(256));
    }

    function test_drawOnlyOnceAndNotForAWhiff() public {
        uint256 id = _commit(0, SALT);
        bytes memory sig = _sign(id);
        derby.draw(id, sig);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.draw(id, sig);
        vm.prank(player);
        uint256 whiff = derby.swing(0, 0, 50, bytes32(0));
        bytes memory whiffSig = _sign(whiff);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.draw(whiff, whiffSig);
    }

    function test_drawWindowCloses() public {
        uint256 id = _commit(0, SALT);
        bytes memory sig = _sign(id);
        vm.warp(T0 + derby.DRAW_WINDOW() + 1);
        vm.expectRevert(SwarmDerby.DrawClosed.selector);
        derby.draw(id, sig);
    }

    function test_noDrawRefundsTurnAndCapOnce() public {
        uint256 id = _commit(0, SALT);
        assertEq(derby.turns(0, player), 4);
        assertEq(derby.arcadeSwingsLeft(player), 19);
        vm.warp(T0 + derby.DRAW_WINDOW());
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id);
        vm.warp(T0 + derby.DRAW_WINDOW() + 1);
        vm.expectEmit(true, true, false, true, address(derby));
        emit SwarmDerby.SwingRefunded(id, player, 0);
        derby.expire(id);
        assertEq(derby.turns(0, player), 5);
        assertEq(derby.arcadeSwingsLeft(player), 20);
        (,,,, SwarmDerby.Status st,,,,) = derby.swings(id);
        assertEq(uint8(st), uint8(SwarmDerby.Status.Refunded));
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.expire(id);
        vm.expectRevert(SwarmDerby.WrongStatus.selector);
        derby.finalize(id, SALT);
    }

    function test_noDrawRefundsAgentTurn() public {
        uint256 id = _commit(1, SALT);
        vm.warp(T0 + derby.DRAW_WINDOW() + 1);
        derby.expire(id);
        assertEq(derby.turns(1, player), 5);
    }

    function test_drawnButUnrevealedIsAFoulNotARefund() public {
        uint256 id = _commit(0, SALT);
        derby.draw(id, _sign(id));
        vm.warp(T0 + derby.DRAW_WINDOW() + 1);
        vm.expectRevert(SwarmDerby.NotExpired.selector);
        derby.expire(id); // drawn: no refund path, and the reveal window is still open
        vm.warp(T0 + derby.DRAW_WINDOW() + derby.REVEAL_WINDOW() + 1);
        vm.expectEmit(true, true, false, true, address(derby));
        emit SwarmDerby.SwingResolved(id, player, DerbyOdds.FOUL, 0);
        derby.expire(id);
        assertEq(derby.turns(0, player), 4);
    }

    /// C-M1: the outcome depends only on the salt and the draw, not on any block data.
    function test_blockDataCannotSteerTheRoll() public {
        uint256 id = _commit(0, SALT);
        derby.draw(id, _sign(id));
        uint256 snap = vm.snapshotState();
        (uint8 tier, uint16 feet) = derby.finalize(id, SALT);
        for (uint256 i = 1; i <= 5; ++i) {
            vm.revertToState(snap);
            snap = vm.snapshotState();
            vm.roll(block.number + i * 7);
            vm.prevrandao(keccak256(abi.encode("block", i)));
            vm.coinbase(address(uint160(i)));
            vm.warp(block.timestamp + i);
            (uint8 t, uint16 f) = derby.finalize(id, SALT);
            assertEq(t, tier);
            assertEq(f, feet);
        }
    }

    function test_reusedCommitRejected() public {
        _commit(0, SALT);
        bytes32 c = derby.commitFor(SALT, player);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.CommitUsed.selector);
        derby.swing(1, 100, 100, c);
    }

    /// Someone who copies a player's commit only burns a turn of their own; the owner keeps it.
    function test_copiedCommitDoesNotBlockItsOwner() public {
        address other = address(0x0BE);
        imd.mint(other, 10 ether);
        vm.startPrank(other);
        imd.approve(address(derby), type(uint256).max);
        derby.buyTurns(1, 1);
        bytes32 c = derby.commitFor(SALT, player);
        uint256 copy = derby.swing(1, 100, 100, c);
        vm.stopPrank();
        uint256 id = _commit(1, SALT);
        derby.draw(id, _sign(id));
        derby.finalize(id, SALT);
        derby.draw(copy, _sign(copy));
        vm.expectRevert(SwarmDerby.BadSalt.selector);
        derby.finalize(copy, SALT);
    }

    function test_houseKeyProposalCanBeCancelledAndLapses() public {
        bytes memory other = bytes.concat(_houseKey());
        other[255] = bytes1(uint8(other[255]) ^ 0x02);
        vm.expectRevert(SwarmDerby.KeyNotReady.selector);
        derby.cancelHouseKey();
        derby.proposeHouseKey(other);
        vm.prank(player);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.cancelHouseKey();
        vm.expectEmit(false, false, false, true, address(derby));
        emit SwarmDerby.HouseKeyProposed(bytes32(0), 0);
        derby.cancelHouseKey();
        assertEq(derby.pendingHouseKeyAt(), 0);
        assertEq(derby.pendingHouseKey().length, 0);
        vm.warp(T0 + 2 days);
        vm.expectRevert(SwarmDerby.KeyNotReady.selector);
        derby.activateHouseKey();

        derby.proposeHouseKey(other); // ready at T0 + 4 days, lapses after T0 + 5 days
        vm.warp(T0 + 5 days + 1);
        vm.expectRevert(SwarmDerby.KeyExpired.selector);
        derby.activateHouseKey();
        vm.warp(T0 + 5 days);
        derby.activateHouseKey();
        assertEq(keccak256(derby.houseKey()), keccak256(other));
    }

    function test_houseKeyChangeWaitsForTheDelay() public {
        bytes memory key = _houseKey();
        bytes memory other = bytes.concat(key);
        other[255] = bytes1(uint8(other[255]) ^ 0x02); // still odd and 2048-bit
        vm.prank(player);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.proposeHouseKey(other);

        vm.expectEmit(false, false, false, true, address(derby));
        emit SwarmDerby.HouseKeyProposed(keccak256(other), T0 + 2 days);
        derby.proposeHouseKey(other);
        vm.warp(T0 + 2 days - 1);
        vm.expectRevert(SwarmDerby.KeyNotReady.selector);
        derby.activateHouseKey();
        // The old key still draws until the new one is active.
        uint256 id = _commit(0, SALT);
        derby.draw(id, _sign(id));

        vm.warp(T0 + 2 days);
        uint256 id2 = _commit(0, keccak256("after"));
        bytes memory sig2 = _sign(id2);
        vm.prank(player); // anyone can activate
        derby.activateHouseKey();
        assertEq(keccak256(derby.houseKey()), keccak256(other));
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(id2, sig2);
        vm.expectRevert(SwarmDerby.KeyNotReady.selector);
        derby.activateHouseKey();
        vm.warp(T0 + 2 days + derby.DRAW_WINDOW() + 1);
        derby.expire(id2);
        assertEq(derby.turns(0, player), 4); // the old-key swing refunds; the earlier draw spent one
        assertEq(derby.arcadeSwingsLeft(player), 19); // both commits were on the same UTC day
    }

    function test_badKeysRejected() public {
        bytes memory key = _houseKey();
        bytes memory short = new bytes(255);
        short[0] = 0x80;
        vm.expectRevert(SwarmDerby.BadKey.selector);
        derby.proposeHouseKey(short);
        bytes memory even = bytes.concat(key);
        even[255] = bytes1(uint8(even[255]) & 0xfe);
        vm.expectRevert(SwarmDerby.BadKey.selector);
        derby.proposeHouseKey(even);
        bytes memory low = bytes.concat(key);
        low[0] = 0x7f;
        vm.expectRevert(SwarmDerby.BadKey.selector);
        derby.proposeHouseKey(low);
        vm.expectRevert(SwarmDerby.BadKey.selector);
        _deployDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether, even);
        vm.expectRevert(SwarmDerby.BadKey.selector);
        _deployDerby(address(this), IERC20(address(imd)), 0.15 ether, 0.5 ether, low);
    }

    function test_revokeStopsDrawsAtOnceAndSwingsRefund() public {
        uint256 id = _commit(0, SALT);
        bytes memory sig = _sign(id);
        derby.proposeHouseKey(_houseKey());
        vm.prank(player);
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.revokeHouseKey();
        derby.revokeHouseKey();
        assertEq(derby.houseKey().length, 0);
        assertEq(derby.pendingHouseKeyAt(), 0);
        vm.expectRevert(SwarmDerby.BadDraw.selector);
        derby.draw(id, sig);
        // No new swing while no key is set: no turn moves. A miss needs no draw.
        bytes32 c = derby.commitFor(keccak256("later"), player);
        vm.startPrank(player);
        vm.expectRevert(SwarmDerby.NoHouseKey.selector);
        derby.swing(1, 100, 100, c);
        derby.swing(1, 0, 0, bytes32(0));
        vm.stopPrank();
        assertEq(derby.turns(1, player), 4);
        vm.warp(T0 + derby.DRAW_WINDOW() + 1);
        derby.expire(id);
        assertEq(derby.turns(0, player), 5);
    }
}
