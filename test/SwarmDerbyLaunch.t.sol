// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby} from "../src/SwarmDerby.sol";

/// Test-only factory: the application must be fully initialized by CREATE2 with zero ETH.
contract DerbyLaunchProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (SwarmDerby derby) {
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "deployment failed");
        return SwarmDerby(deployed);
    }
}

contract SwarmDerbyLaunchTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes constant LAUNCH_MODULUS =
        hex"9b7398ccc4834a29c3064efa2b3530e31022109a8dc6a654bfa878ae0059a2a2c3ac9f31916c0a320a2c179109e395905fc821aab91a1136523c1b90bce1536fe5c11ab65de79551875327766c99e74f9243761f0b3c8d323194bd7f3da77086e27991d5ac2e46ec41b36dc3e959b99dfd40e309277beda06980f5d5d59dd86f2d3d01738e7773bfada03634ac9d8611b31f274422bf36137afdf465a406d299433bf548042816d7aa6b6f69e007bc70d5acb0db4a5c8f19cecbaf31728faa399b0b143d34eb956a2230fe75fdaed887cbd68f7154d1abfb62204e928b9c4e9b54ab9cc7bf171f27a16aa37d8a4a7a02f54b7ab2056befbbffcfbdb24506863d";

    // Independent static-word encoding, exactly as the launch factory must append it.
    function _args() internal view returns (bytes memory) {
        return abi.encode(
            address(this),
            IMD,
            uint256(150000000000000000),
            uint256(500000000000000000),
            bytes32(0x9b7398ccc4834a29c3064efa2b3530e31022109a8dc6a654bfa878ae0059a2a2),
            bytes32(0xc3ac9f31916c0a320a2c179109e395905fc821aab91a1136523c1b90bce1536f),
            bytes32(0xe5c11ab65de79551875327766c99e74f9243761f0b3c8d323194bd7f3da77086),
            bytes32(0xe27991d5ac2e46ec41b36dc3e959b99dfd40e309277beda06980f5d5d59dd86f),
            bytes32(0x2d3d01738e7773bfada03634ac9d8611b31f274422bf36137afdf465a406d299),
            bytes32(0x433bf548042816d7aa6b6f69e007bc70d5acb0db4a5c8f19cecbaf31728faa39),
            bytes32(0x9b0b143d34eb956a2230fe75fdaed887cbd68f7154d1abfb62204e928b9c4e9b),
            bytes32(0x54ab9cc7bf171f27a16aa37d8a4a7a02f54b7ab2056befbbffcfbdb24506863d)
        );
    }

    function _initCode() internal view returns (bytes memory) {
        bytes memory args = _args();
        assertEq(args.length, 12 * 32);
        return bytes.concat(type(SwarmDerby).creationCode, args);
    }

    function test_factoryDeploysExactLaunchConfigurationWithoutToken() public {
        assertEq(IMD.code.length, 0);
        DerbyLaunchProbe factory = new DerbyLaunchProbe();
        bytes memory code = _initCode();
        assertLe(code.length, 49_152);
        bytes32 salt = keccak256("SwarmDerby v2 launch rehearsal");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(code)))))
        );
        vm.expectEmit(false, false, false, true, predicted);
        emit SwarmDerby.HouseKeySet(keccak256(LAUNCH_MODULUS));
        vm.expectEmit(true, true, false, true, predicted);
        emit SwarmDerby.OwnershipTransferred(address(0), address(this));
        SwarmDerby derby = factory.deploy(code, salt);
        assertEq(address(derby), predicted);
        assertEq(derby.owner(), address(this));
        assertEq(address(derby.imd()), IMD);
        assertEq(derby.singlePrice(), 150000000000000000);
        assertEq(derby.packPrice(), 500000000000000000);
        assertEq(derby.houseKey(), LAUNCH_MODULUS);
        assertEq(derby.houseKey().length, 256);
        assertEq(derby.pendingHouseKey().length, 0);
        assertEq(derby.pendingHouseKeyAt(), 0);
        assertEq(IMD.code.length, 0);
        assertEq(address(derby).balance, 0);
        vm.prank(address(factory));
        vm.expectRevert(SwarmDerby.NotOwner.selector);
        derby.setPrices(150000000000000000, 500000000000000000);
        derby.setPrices(150000000000000000, 500000000000000000);

        bytes memory runtime = address(derby).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function test_constructorDoesNotCallToken() public {
        // Every token call would revert; construction only stores the supplied address.
        vm.etch(IMD, hex"60006000fd");
        DerbyLaunchProbe factory = new DerbyLaunchProbe();
        SwarmDerby derby = factory.deploy(_initCode(), keccak256("reverting dependency"));
        assertEq(address(derby.imd()), IMD);
        assertEq(derby.houseKey(), LAUNCH_MODULUS);
    }

    function test_constructorRejectsMissingKeyWord() public {
        DerbyLaunchProbe factory = new DerbyLaunchProbe();
        bytes memory code = _initCode();
        assembly ("memory-safe") { mstore(code, sub(mload(code), 32)) }
        vm.expectRevert("deployment failed");
        factory.deploy(code, keccak256("truncated arguments"));
    }

    function test_constructorIsNonpayable() public {
        bytes memory code = _initCode();
        vm.deal(address(this), 1);
        address deployed;
        assembly ("memory-safe") { deployed := create(1, add(code, 32), mload(code)) }
        assertEq(deployed, address(0));
        assertEq(address(this).balance, 1);
    }
}
