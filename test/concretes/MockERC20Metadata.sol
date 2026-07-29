// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

/// @notice Minimal ERC20 decimals stub for pool initialize currency metadata.
contract MockERC20Metadata {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}
