// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "solady/utils/ECDSA.sol";
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

/// @notice Minimal ERC-1271 smart wallet controlled by one ECDSA key.
contract MockSmartWallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.tryRecoverCalldata(hash, signature) == signer ? MAGIC : bytes4(0xffffffff);
    }
}

/// @notice Contract without ERC-1271, used as an EIP-7702 delegation target.
contract EmptyDelegate {}
