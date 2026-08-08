// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

import {MedianPriorityFeeHook} from "../src/MPFHook.sol";

/// @notice Mines the address and deploys the MedianPriorityFeeHook.sol Hook contract
contract DeployHookScript is BaseScript {
    function run() public {
        HelperConfig.DeploymentConfig memory deploymentConfig = HelperConfig.getDeploymentConfig();

        uint256 tokenCount = deploymentConfig.soundTokens.length;
        address[] memory listedTokens = deploymentConfig.soundTokens;

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        IPoolManager poolManager = IPoolManager(deploymentConfig.poolManager);
        bytes memory constructorArgs = abi.encode(poolManager, listedTokens);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(MedianPriorityFeeHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        MedianPriorityFeeHook medianPriorityFeeHook = new MedianPriorityFeeHook{salt: salt}(poolManager, listedTokens);
        vm.stopBroadcast();

        require(address(medianPriorityFeeHook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
