// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Finds a CREATE2 salt whose resulting address carries exactly the requested Uniswap v4 hook flags in
///         its lowest 14 bits. For the LiquidityMigrator the target is BEFORE_INITIALIZE only (1 << 13): about one
///         address in 16,384 qualifies. Run it with gas metering paused (scripts and tests do).
library HookMiner {
    /// @dev Hooks.ALL_HOOK_MASK in v4-core.
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;
    uint256 internal constant MAX_ITERATIONS = 1_000_000;

    error HookAddressNotFound();

    /// @param deployer CREATE2 deployer (e.g. the Arachnid factory used by `forge script`).
    /// @param flags Exact value the address must have in its lowest 14 bits.
    /// @param initCode Creation code with ABI-encoded constructor arguments appended.
    /// @param startSalt First salt to try (lets several deployments search disjoint ranges).
    function find(address deployer, uint160 flags, bytes memory initCode, uint256 startSalt)
        internal
        view
        returns (bytes32 salt, address hookAddress)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            salt = bytes32(startSalt + i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) return (salt, hookAddress);
        }
        revert HookAddressNotFound();
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
