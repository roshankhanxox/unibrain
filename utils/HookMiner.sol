// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library HookMiner {
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address, bytes32) {
        address hookAddress;
        bytes32 salt;

        // Increase iterations to find a valid address
        for (uint256 i = 0; i < 100000; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(
                deployer,
                salt,
                creationCode,
                constructorArgs
            );

            // Check if the address has the required flags
            uint160 addressFlags = uint160(hookAddress) & flags;
            if (addressFlags == flags) {
                return (hookAddress, salt);
            }
        }
        revert("Could not find valid address within iteration limit");
    }

    function computeAddress(
        address deployer,
        bytes32 salt,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                keccak256(
                                    abi.encodePacked(
                                        creationCode,
                                        constructorArgs
                                    )
                                )
                            )
                        )
                    )
                )
            );
    }

    function validateAddress(
        address hookAddress,
        uint160 expectedFlags
    ) internal pure returns (bool) {
        uint160 addressFlags = uint160(hookAddress) & expectedFlags;
        return addressFlags == expectedFlags;
    }
}
