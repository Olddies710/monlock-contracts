// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CloneWithArgs
/// @notice Minimal ERC-1167 proxies with immutable arguments appended to their runtime code (the layout of Solady's
///         `LibClone` clones with immutable args, re-implemented here to keep that library's deprecated-assembly
///         warnings out of the build). Runtime code of a clone:
///             363d3d373d3d3d363d73 <implementation> 5af43d82803e903d91602b57fd5bf3 <args>
///         The implementation reads the arguments back from its own code with EXTCODECOPY: they cost no storage.
library CloneWithArgs {
    /// @dev Length of the ERC-1167 runtime before the arguments.
    uint256 internal constant ARGS_OFFSET = 0x2d;

    error CloneDeploymentFailed();
    error ArgsTooLong();
    error NotAClone();

    /// @notice CREATE2 init code of a clone: a 10-byte constructor that returns the runtime code that follows it.
    function initCode(address implementation, bytes memory args) internal pure returns (bytes memory) {
        bytes memory runtime =
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3", args);
        if (runtime.length > type(uint16).max) revert ArgsTooLong();
        // PUSH2 len, RETURNDATASIZE, DUP2, PUSH1 0x0a, RETURNDATASIZE, CODECOPY, RETURN.
        // forge-lint: disable-next-line(unsafe-typecast)
        return abi.encodePacked(hex"61", uint16(runtime.length), hex"3d81600a3d39f3", runtime); // bounded above
    }

    function deployDeterministic(address implementation, bytes memory args, bytes32 salt)
        internal
        returns (address instance)
    {
        bytes memory code = initCode(implementation, args);
        assembly ("memory-safe") {
            instance := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (instance == address(0)) revert CloneDeploymentFailed();
    }

    function predictDeterministicAddress(address implementation, bytes memory args, bytes32 salt, address deployer)
        internal
        pure
        returns (address)
    {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(initCode(implementation, args))));
        return address(uint160(uint256(hash)));
    }

    /// @notice Arguments of the executing clone. Reverts unless the code is exactly a clone with `length` bytes of
    ///         arguments, so calls made on the implementation itself fail instead of reading its bytecode as args.
    function argsOfSelf(uint256 length) internal view returns (bytes memory args) {
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(address())
        }
        if (size != ARGS_OFFSET + length) revert NotAClone();
        args = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(address(), add(args, 0x20), ARGS_OFFSET, length)
        }
    }
}
