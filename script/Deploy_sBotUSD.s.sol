// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {sBotUSD} from "../src/sBotUSD.sol";

contract DeploysBotUSD is Script {
    // Deployment configuration
    struct DeployConfig {
        address asset; // BotUSD token address (the base vault)
        address owner; // Contract owner
        address rewardSilo; // RewardSilo address for staking rewards
        string vaultName; // Vault token name
        string vaultSymbol; // Vault token symbol
    }

    function run() external {
        // Get private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Configure deployment parameters
        DeployConfig memory config = getDeployConfig();

        console.log("=== PRE-BROADCAST DEBUG ===");
        console.log("Deployer address:", deployer);
        console.log("BotUSD (asset):", config.asset);
        console.log("Owner:", config.owner);
        console.log("RewardSilo:", config.rewardSilo);
        console.log("Vault name:", config.vaultName);
        console.log("Vault symbol:", config.vaultSymbol);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== POST-BROADCAST ===");
        console.log("Broadcasting transactions...");

        // Deploy implementation contract
        console.log("Deploying sBotUSD implementation...");
        sBotUSD sBotUSDImpl = new sBotUSD();

        // Deploy sBotUSD proxy
        console.log("Deploying sBotUSD proxy...");
        bytes memory initData = abi.encodeCall(
            sBotUSD.initialize,
            (
                IERC20(config.asset),
                config.vaultName,
                config.vaultSymbol,
                config.owner,
                config.rewardSilo
            )
        );

        ERC1967Proxy sBotUSDProxy = new ERC1967Proxy(address(sBotUSDImpl), initData);

        vm.stopBroadcast();

        // Log deployment addresses
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base");
        console.log("Deployer:", deployer);
        console.log("BotUSD (asset):", config.asset);
        console.log("Owner:", config.owner);
        console.log("RewardSilo:", config.rewardSilo);
        console.log("\n=== IMPLEMENTATION CONTRACT ===");
        console.log("sBotUSD Implementation:", address(sBotUSDImpl));
        console.log("\n=== PROXY CONTRACT ===");
        console.log("sBotUSD Proxy:", address(sBotUSDProxy));

        // Verify deployment
        console.log("\n=== VERIFICATION ===");
        sBotUSD vault = sBotUSD(payable(address(sBotUSDProxy)));

        console.log("sBotUSD name:", vault.name());
        console.log("sBotUSD symbol:", vault.symbol());
        console.log("sBotUSD decimals:", vault.decimals());
        console.log("sBotUSD asset:", address(vault.asset()));
        console.log("sBotUSD owner:", vault.owner());
        console.log("sBotUSD riskAdmin:", vault.riskAdmin());
        console.log("sBotUSD silo:", address(vault.silo()));
        console.log("sBotUSD paused:", vault.paused());
        console.log("sBotUSD totalAssets:", vault.totalAssets());

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Call RewardSilo.setVault() to complete the connection:");
        console.log("   forge script script/DeployRewardSilo.s.sol:SetRewardSiloVault \\");
        console.log("     --rpc-url $BASE_RPC_URL --broadcast");
        console.log("   Required env vars:");
        console.log("   - REWARD_SILO=", config.rewardSilo);
        console.log("   - SBOTUSD_ADDRESS=", address(sBotUSDProxy));

        console.log("\n=== SAVE THESE ADDRESSES ===");
        console.log("# Copy this to your .env file:");
        console.log("SBOTUSD_IMPL=", address(sBotUSDImpl));
        console.log("SBOTUSD_ADDRESS=", address(sBotUSDProxy));
    }

    function getDeployConfig() internal view returns (DeployConfig memory) {
        // Required parameters
        address asset = vm.envAddress("BOTUSD_ADDRESS");
        address owner = vm.envAddress("BF_GOV");
        address rewardSilo = vm.envAddress("REWARD_SILO");

        // Vault name and symbol
        string memory vaultName = "Staked BotUSD";
        string memory vaultSymbol = "sBotUSD";

        return DeployConfig({
            asset: asset,
            owner: owner,
            rewardSilo: rewardSilo,
            vaultName: vaultName,
            vaultSymbol: vaultSymbol
        });
    }
}

contract DeploysBotUSDImpl is Script {
    /// Env:
    ///  - PRIVATE_KEY : uint256 (required)
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        sBotUSD impl = new sBotUSD(); // constructor should _disableInitializers()
        vm.stopBroadcast();

        console.log("Deployed sBotUSD implementation:");
        console.logAddress(address(impl));
    }
}