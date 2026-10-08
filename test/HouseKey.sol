// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDerby, IERC20} from "../src/SwarmDerby.sol";
import {HouseDraw} from "../src/HouseDraw.sol";

/// A well-formed key that no signature matches; FakeDrawDerby never checks it.
function dummyHouseKey() pure returns (bytes memory k) {
    k = new bytes(256);
    k[0] = 0x80;
    k[255] = 0x01;
}

/// Test-only SwarmDerby that accepts any 256-byte draw, so a test can pick a swing's outcome.
/// The real signature check is tested with the test house key (HouseDraw.t.sol, SwarmDerbyDraw.t.sol).
contract FakeDrawDerby is SwarmDerby {
    constructor(address owner_, IERC20 imd_, uint256 singlePrice_, uint256 packPrice_)
        SwarmDerby(owner_, imd_, singlePrice_, packPrice_, dummyHouseKey())
    {}

    function _drawValid(bytes memory, bytes calldata sig) internal pure override returns (bool) {
        return sig.length == 256;
    }
}

/// The test house key of test/fixtures/house-test-key.mjs (`modulus`, `exponent`). It is public on
/// purpose and signs only in tests; the real house key never enters the repo.
abstract contract HouseKeyTest is Test {
    bytes internal constant TEST_HOUSE_MODULUS =
        hex"ba7d879cfa8735a4d6e196dfbc2bd3ef8af28a00a319289c890b544b8e5b44017f57f13c25e62e0b36f3513f59e5af554026503fd0d0c053766dfbc2b619c63812dc2e745a0fd867b962ab5b6627d6f1faf8b856391a940f45af09d71dbb4c20073ec3085cc54875505ed987eab97912ced0432b537f1a283531bc6c88a500973c0f6a9ddc9ad74c48e5530104728338816f5e8269a53dc8a0b0d7e8d6c83903996ea42bab3afe4c2b291a0317d15058e8efd645bc35a3bd84a71bc6abf9cef390410728d05e129432f438b35853ca4a6eeea005c3032fe13b9f59754fd37d35e8dbbda949c4a8ab7fa6d599a33301028dbb90bc8c9cf8830162a1cbd800db8f";
    bytes internal constant TEST_HOUSE_EXPONENT =
        hex"4c08a221fe82e1fc332006c37194ecf3dd52c5b13cce2520ad3f513efceb78eea35cd79e0e55aab027d74c68e7de1d7e44895a6eaa5472159553823200ccc1645b4c2a248613afc79a6e002f63971aabce075a20cd6768b65152ec50286f14ba7a39bc8acc482322b181fa6ecfe48ed87c39ad291d01d5484f67d7cae86b5db199177fc012fda72d2a8dc50fa14ee7522783af6769c6138ccfd647e434c03010830053453a1dde841406ade840ca999a976287443716f4e82d9b68613ddc933c4d73b34dd4e5f61b7c32eb93e764ab1e07a01166aaffad8e86eac0b55fb3334422b4daf326ebfd80db8520d9d913e781f9d3ba79ef96c3287f2b24f9c156fb01";

    function _houseKey() internal pure returns (bytes memory) {
        return TEST_HOUSE_MODULUS;
    }

    /// RSASSA-PKCS1-v1_5 (SHA-256) signature, the same bytes the house service sends.
    function _houseSign(bytes memory message) internal view returns (bytes memory sig) {
        bool ok;
        (ok, sig) = address(5).staticcall(
            abi.encodePacked(
                uint256(256), uint256(256), uint256(256), HouseDraw.encoded(message), TEST_HOUSE_EXPONENT, TEST_HOUSE_MODULUS
            )
        );
        require(ok && sig.length == 256, "modexp failed");
    }

    /// A 256-byte draw a FakeDrawDerby accepts.
    function _fakeSig(bytes32 seed) internal pure returns (bytes memory) {
        return bytes.concat(seed, new bytes(224));
    }
}
