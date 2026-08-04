// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script} from "forge-std/Script.sol";

// If we are on a local Anvil, we deploy the mocks
// Else, grab the existing address from the live network
contract HelperConfig {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address priceFeed; // ETH/USD price feed address
    }

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory sepoliaConfig = NetworkConfig({priceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306});
        return sepoliaConfig;
    }
    function getAnvilEthConfig() public pure returns (NetworkConfig memory) {}
}
