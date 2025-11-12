// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RewardSilo} from "../src/RewardSilo.sol";
import {IMintableBotUSD} from "../src/RewardSilo.sol";

contract DeployRewardSilo is Script {
    // Deployment configuration
    struct DeployConfig {
        address botUSD; // BotUSD token address (IMintableBotUSD)
        address owner; // Contract owner (should match BotUSD vault owner)
        address vault; // StakingVault address authorized to withdraw
        address feeReceiver; // Optional fee receiver (can be address(0))
        uint256 initFee; // Initial performance fee in bips (0-8000, can be 0)
    }

    function run() external {
        // Get private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Configure deployment parameters
        DeployConfig memory config = getDeployConfig();

        console.log("=== PRE-BROADCAST DEBUG ===");
        console.log("Deployer address:", deployer);
        console.log("BotUSD address:", config.botUSD);
        console.log("Owner address:", config.owner);
        console.log("Vault address:", config.vault);
        console.log("Fee receiver:", config.feeReceiver);
        console.log("Init fee (bips):", config.initFee);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== POST-BROADCAST ===");
        console.log("Broadcasting transactions...");

        // Deploy implementation contract
        console.log("Deploying RewardSilo implementation...");
        RewardSilo rewardSiloImpl = new RewardSilo();

        // Deploy RewardSilo proxy
        console.log("Deploying RewardSilo proxy...");
        bytes memory initData = abi.encodeCall(
            RewardSilo.initialize,
            (IMintableBotUSD(config.botUSD), config.owner, config.vault, config.feeReceiver, config.initFee)
        );

        ERC1967Proxy rewardSiloProxy = new ERC1967Proxy(address(rewardSiloImpl), initData);

        vm.stopBroadcast();

        // Log deployment addresses
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base");
        console.log("Deployer:", deployer);
        console.log("BotUSD:", config.botUSD);
        console.log("Owner:", config.owner);
        console.log("Vault:", config.vault);
        console.log("Fee Receiver:", config.feeReceiver);
        console.log("Init Fee:", config.initFee, "bips");
        console.log("\n=== IMPLEMENTATION CONTRACT ===");
        console.log("RewardSilo Implementation:", address(rewardSiloImpl));
        console.log("\n=== PROXY CONTRACT ===");
        console.log("RewardSilo Proxy:", address(rewardSiloProxy));

        // Verify deployment
        console.log("\n=== VERIFICATION ===");
        RewardSilo silo = RewardSilo(payable(address(rewardSiloProxy)));

        console.log("RewardSilo asset:", address(silo.asset()));
        console.log("RewardSilo owner:", silo.owner());
        console.log("RewardSilo vault:", silo.vault());
        console.log("RewardSilo feeReceiver:", silo.feeReceiver());
        console.log("RewardSilo performanceFee:", silo.performanceFee(), "bips");
        console.log("RewardSilo dripDuration:", silo.dripDuration(), "seconds");
        console.log("RewardSilo paused:", silo.paused());

        console.log("\n=== SAVE THESE ADDRESSES ===");
        console.log("# Copy this to your .env file:");
        console.log("REWARD_SILO_IMPL=", address(rewardSiloImpl));
        console.log("REWARD_SILO=", address(rewardSiloProxy));
    }

    function getDeployConfig() internal view returns (DeployConfig memory) {
        // Required parameters
        address botUSD = vm.envAddress("BOTUSD_ADDRESS");
        address owner = vm.envAddress("BF_GOV");
        address vault = vm.envAddress("STAKED_BOTUSD_ADDRESS");

        // Optional parameters - default to address(0) and 0 if not set
        address feeReceiver;
        try vm.envAddress("FEE_RECEIVER") returns (address receiver) {
            feeReceiver = receiver;
        } catch {
            feeReceiver = address(0);
            console.log("FEE_RECEIVER not set, using address(0)");
        }

        uint256 initFee;
        try vm.envUint("INIT_FEE_BIPS") returns (uint256 fee) {
            require(fee <= 8000, "Fee too high (max 8000 bips)");
            initFee = fee;
        } catch {
            initFee = 0;
            console.log("INIT_FEE_BIPS not set, using 0");
        }

        return DeployConfig({botUSD: botUSD, owner: owner, vault: vault, feeReceiver: feeReceiver, initFee: initFee});
    }
}

contract DeployRewardSiloImpl is Script {
    /// Env:
    ///  - PRIVATE_KEY : uint256 (required)
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        RewardSilo impl = new RewardSilo(); // constructor should _disableInitializers()
        vm.stopBroadcast();

        console.log("Deployed RewardSilo implementation:");
        console.logAddress(address(impl));
    }
}
