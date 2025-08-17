// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StrategyManager} from "../src/StrategyManager.sol";
import {Pausable4626Vault} from "../src/Pausable4626Vault.sol";

contract DeployScript is Script {
    // Base network addresses
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Deployment configuration - UPDATE THESE
    struct DeployConfig {
        address asset; // Asset token (WETH)
        address owner; // Contract owner
        address treasury; // Treasury address for fees
        address exec; // Executor address
        address fulfiller; // Fulfiller address for vault
        string vaultName; // Vault token name
        string vaultSymbol; // Vault token symbol
    }

    function run() external {
        // Get private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Configure deployment parameters
        DeployConfig memory config = getDeployConfig(deployer);

        console.log("=== PRE-BROADCAST DEBUG ===");
        console.log("Deployer address:", deployer);
        // Remove balance check as it might cause RPC issues
        // console.log("Deployer balance:", deployer.balance);
        console.log("Config owner:", config.owner);
        console.log("Config treasury:", config.treasury);

        vm.startBroadcast();

        console.log("=== POST-BROADCAST ===");
        console.log("Broadcasting transactions...");

        // Deploy implementation contracts
        console.log("Deploying StrategyManager implementation...");
        StrategyManager strategyManagerImpl = new StrategyManager();

        console.log("Deploying Pausable4626Vault implementation...");
        Pausable4626Vault vaultImpl = new Pausable4626Vault(WETH_BASE);

        // Deploy StrategyManager proxy
        console.log("Deploying StrategyManager proxy...");
        bytes memory strategyManagerInitData = abi.encodeCall(
            StrategyManager.initialize,
            (IERC20(config.asset), config.owner, config.treasury, config.exec)
        );

        ERC1967Proxy strategyManagerProxy = new ERC1967Proxy(
            address(strategyManagerImpl),
            strategyManagerInitData
        );

        // Deploy Vault proxy
        console.log("Deploying Pausable4626Vault proxy...");
        bytes memory vaultInitData = abi.encodeCall(
            Pausable4626Vault.initialize,
            (
                IERC20(config.asset),
                config.vaultName,
                config.vaultSymbol,
                config.owner,
                address(strategyManagerProxy),
                config.fulfiller
            )
        );

        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInitData
        );

        // Set vault address in strategy manager
        console.log("Setting vault address in StrategyManager...");
        StrategyManager(payable(address(strategyManagerProxy))).setVault(
            address(vaultProxy)
        );

        vm.stopBroadcast();

        // Log deployment addresses
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base");
        console.log("Deployer:", deployer);
        console.log("Asset:", config.asset);
        console.log("Owner:", config.owner);
        console.log("Treasury:", config.treasury);
        console.log("Exec:", config.exec);
        console.log("Fulfiller:", config.fulfiller);
        console.log("\n=== IMPLEMENTATION CONTRACTS ===");
        console.log(
            "StrategyManager Implementation:",
            address(strategyManagerImpl)
        );
        console.log("Pausable4626Vault Implementation:", address(vaultImpl));
        console.log("\n=== PROXY CONTRACTS ===");
        console.log("StrategyManager Proxy:", address(strategyManagerProxy));
        console.log("Pausable4626Vault Proxy:", address(vaultProxy));

        // Verify deployment
        console.log("\n=== VERIFICATION ===");
        StrategyManager sm = StrategyManager(
            payable(address(strategyManagerProxy))
        );
        Pausable4626Vault vault = Pausable4626Vault(
            payable(address(vaultProxy))
        );

        console.log("StrategyManager asset:", address(sm.asset()));
        console.log("StrategyManager owner:", sm.owner());
        console.log("StrategyManager vault:", sm.vault());
        console.log("StrategyManager treasury:", sm.treasury());
        console.log("StrategyManager exec:", sm.exec());

        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
        console.log("Vault asset:", address(vault.asset()));
        console.log("Vault owner:", vault.owner());
        console.log("Vault manager:", address(vault.manager()));
        console.log("Vault fulfiller:", vault.fulfiller());
        console.log("Vault paused:", vault.paused());

        console.log("\n=== SAVE THESE ADDRESSES ===");
        console.log("# Copy this to your .env file:");
        console.log("STRATEGY_MANAGER_IMPL=", address(strategyManagerImpl));
        console.log("VAULT_IMPL=", address(vaultImpl));
        console.log("STRATEGY_MANAGER=", address(strategyManagerProxy));
        console.log("VAULT=", address(vaultProxy));
    }

    function getDeployConfig(address deployer) internal view returns (DeployConfig memory) {
        // Try to get config from environment variables, default to deployer
        address owner = vm.envOr("OWNER", deployer);
        address treasury = vm.envOr("TREASURY", deployer);
        address exec = vm.envOr("EXEC", deployer);
        address fulfiller = vm.envOr("FULFILLER", deployer);
        address asset = vm.envOr("ASSET", WETH_BASE);

        return
            DeployConfig({
                asset: asset,
                owner: owner,
                treasury: treasury,
                exec: exec,
                fulfiller: fulfiller,
                vaultName: vm.envOr("VAULT_NAME", string("botfedETH")),
                vaultSymbol: vm.envOr("VAULT_SYMBOL", string("botfedETH"))
            });
    }
}

// Separate script for upgrading contracts
contract UpgradeScript is Script {
    function upgradeStrategyManager(address proxy, address newImpl) external {
        vm.startBroadcast();

        StrategyManager(payable(proxy)).upgradeToAndCall(newImpl, "");

        vm.stopBroadcast();

        console.log("StrategyManager upgraded:");
        console.log("Proxy:", proxy);
        console.log("New Implementation:", newImpl);
    }

    function upgradeVault(address proxy, address newImpl) external {
        vm.startBroadcast();

        Pausable4626Vault(payable(proxy)).upgradeToAndCall(newImpl, "");

        vm.stopBroadcast();

        console.log("Pausable4626Vault upgraded:");
        console.log("Proxy:", proxy);
        console.log("New Implementation:", newImpl);
    }
}