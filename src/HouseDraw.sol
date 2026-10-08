// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Verifiable house draw: the house signs each committed swing with a 2048-bit RSA key
///         (RSASSA-PKCS1-v1_5, SHA-256, e = 65537). For a properly generated key there is exactly
///         one valid signature below the modulus for each message, so the house can't choose the
///         draw, and nobody without the key can predict it. The draw is keccak256(signature).
///         The contract can't check how a key was generated; it only checks the key's shape.
library HouseDraw {
    uint256 internal constant KEY_BYTES = 256;
    // DER DigestInfo header for SHA-256 (RFC 8017, section 9.2, note 1).
    bytes19 internal constant SHA256_DIGEST_INFO = 0x3031300d060960864801650304020105000420;
    // EMSA-PKCS1-v1_5 padding for a 256-byte key: 00 01, 202 bytes of ff, 00.
    bytes internal constant PADDING =
        hex"0001ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00";

    function verify(bytes memory modulus, bytes memory message, bytes memory sig) internal view returns (bool) {
        if (modulus.length != KEY_BYTES || sig.length != KEY_BYTES) return false;
        if (!_below(sig, modulus)) return false;
        (bool ok, bytes memory em) = address(5).staticcall(
            abi.encodePacked(KEY_BYTES, uint256(3), KEY_BYTES, sig, hex"010001", modulus)
        );
        if (!ok || em.length != KEY_BYTES) return false;
        return keccak256(em) == keccak256(encoded(message));
    }

    /// @notice EMSA-PKCS1-v1_5 encoding of sha256(message) for a 2048-bit key.
    function encoded(bytes memory message) internal pure returns (bytes memory) {
        return abi.encodePacked(PADDING, SHA256_DIGEST_INFO, sha256(message));
    }

    /// @dev Big-endian a < b for two KEY_BYTES-long numbers.
    function _below(bytes memory a, bytes memory b) private pure returns (bool) {
        for (uint256 off = 32; off <= KEY_BYTES; off += 32) {
            uint256 x;
            uint256 y;
            assembly {
                x := mload(add(a, off))
                y := mload(add(b, off))
            }
            if (x != y) return x < y;
        }
        return false;
    }
}
