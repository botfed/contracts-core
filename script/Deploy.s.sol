// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StrategyManager} from "../src/StrategyManager.sol";
import {BotUSD} from "../src/BotUSD.sol";

// Interface for WETH validation
interface IERC20Extended {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
}

address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

contract DeployScript is Script {
    // Base network addresses

    // Deployment configuration - UPDATE THESE
    struct DeployConfig {
        address asset; // Asset token (WETH)
        address owner; // Contract owner
        address treasury; // Treasury address for fees
        address exec; // Executor address
        address riskAdmin; // riskAdmin address for vault
        address minter;
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

        require(config.asset == USDC_BASE || config.asset == WETH_BASE, "Asset not USDC or WETH");

        vm.startBroadcast();

        console.log("=== POST-BROADCAST ===");
        console.log("Broadcasting transactions...");

        // Deploy implementation contracts
        console.log("Deploying StrategyManager implementation...");
        StrategyManager strategyManagerImpl = new StrategyManager();

        console.log("Deploying BotUSD implementation...");
        BotUSD vaultImpl = new BotUSD();

        // Deploy StrategyManager proxy
        console.log("Deploying StrategyManager proxy...");
        bytes memory strategyManagerInitData = abi.encodeCall(
            StrategyManager.initialize,
            (IERC20(config.asset), deployer, config.exec)
        );

        ERC1967Proxy strategyManagerProxy = new ERC1967Proxy(address(strategyManagerImpl), strategyManagerInitData);

        // Deploy Vault proxy
        console.log("Deploying BotUSD proxy...");
        bytes memory vaultInitData = abi.encodeCall(
            BotUSD.initialize,
            (
                IERC20(config.asset),
                config.vaultName,
                config.vaultSymbol,
                config.owner,
                address(strategyManagerProxy)
            )
        );

        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);

        // Set vault address in strategy manager
        console.log("Setting vault address in StrategyManager...");
        StrategyManager(payable(address(strategyManagerProxy))).setVault(address(vaultProxy));
        StrategyManager(payable(address(strategyManagerProxy))).transferOwnership(config.owner);

        vm.stopBroadcast();

        // Log deployment addresses
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Base");
        console.log("Deployer:", deployer);
        console.log("Asset:", config.asset);
        console.log("Owner:", config.owner);
        console.log("Treasury:", config.treasury);
        console.log("Exec:", config.exec);
        console.log("\n=== IMPLEMENTATION CONTRACTS ===");
        console.log("StrategyManager Implementation:", address(strategyManagerImpl));
        console.log("BotUSD Implementation:", address(vaultImpl));
        console.log("\n=== PROXY CONTRACTS ===");
        console.log("StrategyManager Proxy:", address(strategyManagerProxy));
        console.log("BotUSD Proxy:", address(vaultProxy));

        // Verify deployment
        console.log("\n=== VERIFICATION ===");
        StrategyManager sm = StrategyManager(payable(address(strategyManagerProxy)));
        BotUSD vault = BotUSD(payable(address(vaultProxy)));

        console.log("StrategyManager asset:", address(sm.asset()));
        console.log("StrategyManager owner:", sm.owner());
        console.log("StrategyManager vault:", sm.vault());
        console.log("StrategyManager exec:", sm.exec());

        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
        console.log("Vault asset:", address(vault.asset()));
        console.log("Vault owner:", vault.owner());
        console.log("Vault manager:", address(vault.manager()));
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
        address owner = vm.envAddress("BF_GOV");
        address treasury = vm.envAddress("BF_TREASURY");
        address riskAdmin = vm.envAddress("BF_RISK_ADMIN");
        address minter = vm.envAddress("BF_MINTER");
        address exec = vm.envAddress("BF_STRAT_MANAGER_EXEC");
        address asset = vm.envAddress("ASSET");

        require(asset == USDC_BASE || asset == WETH_BASE, "Asset not USDC or WETH");

        string memory vaultSymbol = (asset == WETH_BASE ? "botETH" : "botUSD");
        string memory vaultName = (asset == WETH_BASE ? "BotFed ETH" : "BotFed USD");

        return
            DeployConfig({
                asset: asset,
                owner: owner,
                treasury: treasury,
                exec: exec,
                riskAdmin: riskAdmin,
                minter: minter,
                vaultName: vaultName,
                vaultSymbol: vaultSymbol
            });
    }
    function validateWETHAddress(address wethAddr) internal view {
        console.log("=== VALIDATING WETH ADDRESS ===");
        console.log("WETH address to validate:", wethAddr);

        require(wethAddr != address(0), "WETH address cannot be zero");

        // Check if it's a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(wethAddr)
        }
        require(codeSize > 0, "WETH address is not a contract");
        console.log("WETH address is a contract");

        IERC20Extended weth = IERC20Extended(wethAddr);

        // Check symbol
        try weth.symbol() returns (string memory symbol) {
            console.log("Token symbol:", symbol);
            require(
                keccak256(bytes(symbol)) == keccak256(bytes("WETH")) ||
                    keccak256(bytes(symbol)) == keccak256(bytes("ETH")), // Some networks use "ETH"
                "Token symbol is not WETH or ETH"
            );
            console.log("Symbol validation passed");
        } catch {
            revert("Failed to get token symbol");
        }

        // Check decimals
        try weth.decimals() returns (uint8 decimals) {
            console.log("Token decimals:", decimals);
            require(decimals == 18, "Token decimals is not 18");
            console.log("Decimals validation passed");
        } catch {
            revert("Failed to get token decimals");
        }

        // Check that WETH contract has substantial ETH backing (at least 1000 ETH)
        // This verifies it's a real, active WETH contract and not a fake
        uint256 ethBalance = wethAddr.balance;
        console.log("WETH contract ETH balance:", ethBalance / 1e18, "ETH");
        require(ethBalance >= 1000 ether, "WETH contract has less than 1000 ETH - possibly fake or inactive");
        console.log("WETH contract has sufficient ETH backing (>=1000 ETH)");

        // Additional sanity check - try ERC20 balanceOf call
        try weth.balanceOf(address(0)) returns (uint256) {
            // If this call succeeds, it's likely a proper ERC20
            console.log("ERC20 balanceOf call succeeded");
        } catch {
            revert("Failed ERC20 balanceOf call - not a proper ERC20");
        }

        console.log("WETH address validation completed successfully");
    }
}

contract DeployStrategyManagerImpl is Script {
    /// Env:
    ///  - PRIVATE_KEY : uint256 (required)
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        StrategyManager impl = new StrategyManager(); // constructor should _disableInitializers()
        vm.stopBroadcast();

        console.log("Deployed StrategyManager implementation:");
        console.logAddress(address(impl));
    }
}

contract DeployVaultImpl is Script {
    // Deploy a vault implementation bound to the selected ASSET (WETH/USDC)
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        // Use same selection logic as main script
        address asset = vm.envAddress("ASSET");
        require(asset == USDC_BASE || asset == WETH_BASE, "Asset not USDC or WETH");

        vm.startBroadcast(pk);
        BotUSD impl = new BotUSD();
        vm.stopBroadcast();

        console.log("Deployed Vault implementation (asset-bound):");
        console.logAddress(address(impl));
    }
}
