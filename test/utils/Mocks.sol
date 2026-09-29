// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Stand-in for the Phase 3 LiquidityMigrator: records what the curve hands over at graduation.
contract MockMigrator {
    bool public shouldRevert;
    uint256 public calls;
    uint256 public monReceived;
    uint256 public tokensReceived;
    address public lastToken;
    address public lastCurve;

    error MockMigrationFailed();
    error TokensNotReceived();

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function migrate(address token, uint256 tokenAmount) external payable returns (bytes32, uint128) {
        if (shouldRevert) revert MockMigrationFailed();
        if (SafeTransferLib.balanceOf(token, address(this)) < tokensReceived + tokenAmount) revert TokensNotReceived();
        calls++;
        monReceived += msg.value;
        tokensReceived += tokenAmount;
        lastToken = token;
        lastCurve = msg.sender;
        return (bytes32(0), 0);
    }
}

/// @notice Fee recipient that rejects plain MON transfers (exercises forced payouts).
contract RejectingRecipient {
    receive() external payable {
        revert("no MON");
    }
}
