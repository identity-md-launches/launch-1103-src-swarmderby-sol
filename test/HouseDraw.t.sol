// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HouseDraw} from "../src/HouseDraw.sol";
import {HouseKeyTest} from "./HouseKey.sol";

contract HouseDrawHarness {
    function verify(bytes memory n, bytes memory m, bytes memory s) external view returns (bool) {
        return HouseDraw.verify(n, m, s);
    }
}

contract HouseDrawTest is HouseKeyTest {
    HouseDrawHarness h = new HouseDrawHarness();
    bytes n;

    function setUp() public {
        n = _houseKey();
    }

    function test_validSignatures() public {
        assertTrue(h.verify(n, "swing 1", _houseSign("swing 1")));
        bytes memory long = new bytes(224);
        assertTrue(h.verify(n, long, _houseSign(long)));
    }

    function test_signatureIsDeterministic() public {
        assertEq(keccak256(_houseSign("same")), keccak256(_houseSign("same")));
    }

    function test_wrongMessage() public {
        assertFalse(h.verify(n, "swing 2", _houseSign("swing 1")));
    }

    function test_flippedBit() public {
        bytes memory s = _houseSign("swing 1");
        s[200] = bytes1(uint8(s[200]) ^ 1);
        assertFalse(h.verify(n, "swing 1", s));
    }

    /// sig + n gives the same modexp result; only the copy below n may count.
    function test_signaturePlusModulusRejected() public {
        for (uint256 i;; ++i) {
            bytes memory m = abi.encode("low signature", i);
            bytes memory s = _houseSign(m);
            (bool fits, bytes memory sum) = _add(s, n);
            if (!fits) continue;
            assertTrue(h.verify(n, m, s));
            assertFalse(h.verify(n, m, sum));
            return;
        }
    }

    function test_wrongLengths() public {
        bytes memory s = _houseSign("swing 1");
        assertFalse(h.verify(n, "swing 1", bytes.concat(hex"00", s)));
        assertFalse(h.verify(bytes.concat(hex"00", n), "swing 1", bytes.concat(hex"00", s)));
        assertFalse(h.verify(n, "swing 1", new bytes(0)));
    }

    function _add(bytes memory a, bytes memory b) internal pure returns (bool fits, bytes memory sum) {
        sum = new bytes(256);
        uint256 carry;
        for (uint256 i = 256; i > 0; --i) {
            uint256 v = uint256(uint8(a[i - 1])) + uint256(uint8(b[i - 1])) + carry;
            sum[i - 1] = bytes1(uint8(v));
            carry = v >> 8;
        }
        fits = carry == 0;
    }
}
