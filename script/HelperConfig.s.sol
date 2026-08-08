// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// If we are on a local Anvil, we use the mock config
// Else, grab the existing address for the live network
library HelperConfig {
    // CHAIN IDs
    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 internal constant UNICHAIN_MAINNET_CHAIN_ID = 130;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    // The list of Tokens to pass to constuctor
    // to use as tokens Median can trust while
    // being updted. Saves contract from dust attacks.
    struct NetworkConfig {
        address poolManager; // nwtwork-specific Pool Manager Contract
        address[] soundTokens;
    }

    struct DeploymentConfig {
        address poolManager;
        address[] soundTokens;
    }

    // No constructor and no state — the network is resolved fresh
    // on every call from block.chainid.
    function getDeploymentConfig() internal view returns (DeploymentConfig memory) {
        NetworkConfig memory activeNetworkConfig;

        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == ETHEREUM_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getEthereumMainnetConfig();
        } else if (block.chainid == UNICHAIN_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getUnichainConfig();
        } else {
            activeNetworkConfig = getAnvilEthConfig();
        }

        return
            DeploymentConfig({
                poolManager: activeNetworkConfig.poolManager, soundTokens: activeNetworkConfig.soundTokens
            });
    }

    function getSepoliaEthConfig() internal pure returns (NetworkConfig memory) {
        address[] memory soundTokens = new address[](4);
        soundTokens[0] = address(0); // Native Sepolia ETH
        soundTokens[1] = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // WETH
        soundTokens[2] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNI
        soundTokens[3] = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // USDC

        return NetworkConfig({poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, soundTokens: soundTokens});
    }

    function getEthereumMainnetConfig() internal pure returns (NetworkConfig memory) {
        address[] memory soundTokens = new address[](6);
        soundTokens[0] = address(0); // Native ETH
        soundTokens[1] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
        soundTokens[2] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC
        soundTokens[3] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNI
        soundTokens[4] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
        soundTokens[5] = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT

        return NetworkConfig({poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90, soundTokens: soundTokens});
    }

    function getUnichainConfig() internal pure returns (NetworkConfig memory) {
        address[] memory soundTokens = new address[](5);
        soundTokens[0] = address(0); // Native ETH
        soundTokens[1] = 0x4200000000000000000000000000000000000006; // WETH
        soundTokens[2] = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
        soundTokens[3] = 0x8f187aA05619a017077f5308904739877ce9eA21;
        soundTokens[4] = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
        // If you need USDT0 as a 6th token, uncomment and size the array to 6:
        // soundTokens[5] = 0x9151434b16b9763660705744891fA906F660EcC5; // USDT0

        return NetworkConfig({poolManager: 0x1F98400000000000000000000000000000000004, soundTokens: soundTokens});
    }

    function getAnvilEthConfig() internal pure returns (NetworkConfig memory) {
        address[] memory soundTokens = new address[](1);
        soundTokens[0] = address(0);

        return NetworkConfig({poolManager: address(0), soundTokens: soundTokens});
    }
}
