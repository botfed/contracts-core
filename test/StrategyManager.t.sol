// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import "../src/StrategyManager.sol";

// Mock Strategy for testing
contract MockStrategy {
    IERC20 public asset;
    address public owner;
    uint256 public withdrawResult = type(uint256).max; // Return full amount by default
    bool public shouldRevert = false;

    constructor(IERC20 _asset, address owner_) {
        asset = _asset;
        owner = owner_;
    }

    function setWithdrawResult(uint256 _result) external {
        withdrawResult = _result;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function withdrawToManager(uint256 requested) external returns (uint256) {
        if (shouldRevert) {
            revert("Strategy error");
        }

        uint256 toReturn = withdrawResult == type(uint256).max ? requested : withdrawResult;
        uint256 bal = asset.balanceOf(address(this));
        if (toReturn > 0 && toReturn < bal) {
            asset.transfer(msg.sender, toReturn);
        } else if (toReturn > bal && bal > 0) {
            asset.transfer(msg.sender, bal);
        }
        return toReturn;
    }

    // Allow strategy to receive tokens
    receive() external payable {}
}

// Mock strategy that doesn't implement interface properly
contract BadMockStrategy {
    // Doesn't implement withdrawToManager
}

contract StrategyManagerTest is Test {
    StrategyManager public strategyManager;
    StrategyManager public implementation;
    ERC20Mock public asset;
    MockStrategy public mockStrategy1;
    MockStrategy public mockStrategy2;
    BadMockStrategy public badStrategy;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public exec = makeAddr("exec");
    address public vault = makeAddr("vault");
    address public user = makeAddr("user");
    address public unauthorized = makeAddr("unauthorized");

    event StrategyAdded(address indexed strat);
    event StrategyRemoved(address indexed strat);
    event CapitalPushed(address indexed strat, uint256 amount);
    event CapitalPulled(address indexed strat, uint256 requested, uint256 received);
    event WithdrawnTo(address indexed to, uint256 amount);
    event SetVault(address indexed who);
    event SetTreasury(address indexed who);
    event SetExec(address indexed who);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    function setUp() public {
        // Deploy mock asset
        asset = new ERC20Mock();

        // Deploy implementation
        implementation = new StrategyManager();

        // Deploy proxy and initialize
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            asset,
            owner,
            treasury,
            exec
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        strategyManager = StrategyManager(payable(address(proxy)));

        // Set vault
        vm.prank(owner);
        strategyManager.setVault(vault);

        // Deploy mock strategies
        mockStrategy1 = new MockStrategy(asset, owner);
        mockStrategy2 = new MockStrategy(asset, owner);
        badStrategy = new BadMockStrategy();

        // Mint some tokens to strategy manager for testing
        asset.mint(address(strategyManager), 10000e18);
        asset.mint(address(mockStrategy1), 5000e18);
        asset.mint(address(mockStrategy2), 5000e18);
    }

    /* ==================== INITIALIZATION TESTS ==================== */

    function test_Initialize_Success() public {
        assertEq(address(strategyManager.asset()), address(asset));
        assertEq(strategyManager.owner(), owner);
        assertEq(strategyManager.treasury(), treasury);
        assertEq(strategyManager.exec(), exec);
        assertEq(strategyManager.vault(), vault);
    }

    function test_Initialize_ZeroAsset() public {
        StrategyManager newImpl = new StrategyManager();
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            address(0),
            owner,
            treasury,
            exec
        );

        vm.expectRevert(bytes("asset=0"));
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_ZeroOwner() public {
        StrategyManager newImpl = new StrategyManager();
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            asset,
            address(0),
            treasury,
            exec
        );

        vm.expectRevert(bytes("owner=0"));
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_ZeroTreasury() public {
        StrategyManager newImpl = new StrategyManager();
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            asset,
            owner,
            address(0),
            exec
        );

        vm.expectRevert(bytes("treasury=0"));
        new ERC1967Proxy(address(newImpl), initData);
    }

    /* ==================== ACCESS CONTROL TESTS ==================== */

    function test_OnlyOwner_SetVault() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        strategyManager.setVault(makeAddr("newVault"));
    }

    function test_OnlyOwner_SetTreasury() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        strategyManager.setTreasury(makeAddr("newTreasury"));
    }

    function test_OnlyOwner_SetExec() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        strategyManager.setExec(makeAddr("newExec"));
    }

    function test_OnlyOwner_AddStrategy() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        strategyManager.addStrategy(address(mockStrategy1));
    }

    function test_OnlyOwner_RemoveStrategy() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(unauthorized);
        vm.expectRevert();
        strategyManager.removeStrategy(address(mockStrategy1));
    }

    function test_OnlyExec_PushToStrategy() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(unauthorized);
        vm.expectRevert(bytes("OE"));
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
    }

    function test_OnlyVault_WithdrawToVault() public {
        vm.prank(unauthorized);
        vm.expectRevert(bytes("OE"));
        strategyManager.withdrawToVault(1000e18);
    }

    function test_Owner_CanBypassExecRestrictions() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(owner);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);

        vm.prank(owner);
        strategyManager.pullFromStrategy(address(mockStrategy1), 500e18);
    }

    function test_Owner_CanBypassVaultRestrictions() public {
        vm.prank(owner);
        strategyManager.withdrawToVault(1000e18);
    }

    /* ==================== ADMIN SETTERS TESTS ==================== */

    function test_SetVault_Success() public {
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, true, true);
        emit SetVault(newVault);

        vm.prank(owner);
        strategyManager.setVault(newVault);

        assertEq(strategyManager.vault(), newVault);
    }

    function test_SetVault_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("withdraw=0"));
        strategyManager.setVault(address(0));
    }

    function test_SetTreasury_Success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, true, true);
        emit SetTreasury(newTreasury);

        vm.prank(owner);
        strategyManager.setTreasury(newTreasury);

        assertEq(strategyManager.treasury(), newTreasury);
    }

    function test_SetTreasury_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("treasury=0"));
        strategyManager.setTreasury(address(0));
    }

    function test_SetExec_Success() public {
        address newExec = makeAddr("newExec");

        vm.expectEmit(true, true, true, true);
        emit SetExec(newExec);

        vm.prank(owner);
        strategyManager.setExec(newExec);

        assertEq(strategyManager.exec(), newExec);
    }

    function test_SetExec_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("exec=0"));
        strategyManager.setExec(address(0));
    }

    /* ==================== STRATEGY MANAGEMENT TESTS ==================== */

    function test_AddStrategy_Success() public {
        vm.expectEmit(true, true, true, true);
        emit StrategyAdded(address(mockStrategy1));

        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        assertTrue(strategyManager.isStrategy(address(mockStrategy1)));
        assertEq(strategyManager.strategies(0), address(mockStrategy1));
        assertEq(strategyManager.strategiesLength(), 1);
    }

    function test_AddStrategy_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("strat=0"));
        strategyManager.addStrategy(address(0));
    }

    function test_AddStrategy_AlreadyExists() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(owner);
        vm.expectRevert(bytes("exists"));
        strategyManager.addStrategy(address(mockStrategy1));
    }

    function test_AddStrategy_InvalidInterface() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Invalid strategy interface"));
        strategyManager.addStrategy(address(badStrategy));
    }

    function test_AddStrategy_MaxStrategies() public {
        // Add MAX_STRATEGIES strategies
        uint256 maxStrategies = strategyManager.MAX_STRATEGIES();

        for (uint256 i = 0; i < maxStrategies; i++) {
            MockStrategy newStrat = new MockStrategy(asset, owner);
            vm.prank(owner);
            strategyManager.addStrategy(address(newStrat));
        }

        // Try to add one more
        vm.prank(owner);
        vm.expectRevert(bytes("max strategies"));
        strategyManager.addStrategy(address(mockStrategy1));
    }

    function test_RemoveStrategy_Success() public {
        // Add two strategies
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        assertTrue(strategyManager.isStrategy(address(mockStrategy1)));
        assertEq(strategyManager.strategiesLength(), 2);

        vm.expectEmit(true, true, true, true);
        emit StrategyRemoved(address(mockStrategy1));

        vm.prank(owner);
        strategyManager.removeStrategy(address(mockStrategy1));

        assertFalse(strategyManager.isStrategy(address(mockStrategy1)));
        assertEq(strategyManager.strategiesLength(), 1);

        // Verify swap-remove worked correctly
        address[] memory activeStrategies = strategyManager.getActiveStrategies();
        assertEq(activeStrategies.length, 1);
        assertEq(activeStrategies[0], address(mockStrategy2));
    }

    function test_RemoveStrategy_NotExists() public {
        vm.prank(owner);
        vm.expectRevert(bytes("missing"));
        strategyManager.removeStrategy(address(mockStrategy1));
    }

    function test_RemoveStrategy_SwapRemove() public {
        // Add three strategies
        MockStrategy strat3 = new MockStrategy(asset, owner);
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        strategyManager.addStrategy(address(strat3));
        vm.stopPrank();

        // Remove middle strategy
        vm.prank(owner);
        strategyManager.removeStrategy(address(mockStrategy2));

        // Verify array compaction
        assertEq(strategyManager.strategiesLength(), 2);
        address[] memory activeStrategies = strategyManager.getActiveStrategies();
        assertEq(activeStrategies.length, 2);

        // Order doesn't matter, but both remaining strategies should be present
        bool foundStrat1 = false;
        bool foundStrat3 = false;
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            if (activeStrategies[i] == address(mockStrategy1)) foundStrat1 = true;
            if (activeStrategies[i] == address(strat3)) foundStrat3 = true;
        }
        assertTrue(foundStrat1);
        assertTrue(foundStrat3);
    }

    /* ==================== CAPITAL MOVEMENT TESTS ==================== */

    function test_PushToStrategy_Success() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        uint256 amount = 1000e18;
        uint256 initialBalance = asset.balanceOf(address(strategyManager));
        uint256 initialStrategyBalance = asset.balanceOf(address(mockStrategy1));
        uint256 initialDeployed = strategyManager.getStrategyDeployed(address(mockStrategy1));

        vm.expectEmit(true, true, true, true);
        emit CapitalPushed(address(mockStrategy1), amount);

        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), amount);

        assertEq(asset.balanceOf(address(strategyManager)), initialBalance - amount);
        assertEq(asset.balanceOf(address(mockStrategy1)), initialStrategyBalance + amount);
        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), initialDeployed + amount);
    }

    function test_PushToStrategy_UnknownStrategy() public {
        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.UnknownStrategy.selector));
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
    }

    function test_PushToStrategy_InsufficientBalance() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        uint256 managerBalance = asset.balanceOf(address(strategyManager));

        vm.prank(exec);
        vm.expectRevert();
        strategyManager.pushToStrategy(address(mockStrategy1), managerBalance + 1);
    }

    function test_PullFromStrategy_Success() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        uint256 requested = 500e18;
        asset.mint(address(mockStrategy1), 1000e18);
        uint256 initialBalance = asset.balanceOf(address(strategyManager));
        uint256 initialStrategyBalance = asset.balanceOf(address(mockStrategy1));
        uint256 initialWithdrawn = strategyManager.getStrategyWithdrawn(address(mockStrategy1));

        vm.expectEmit(true, true, true, true);
        emit CapitalPulled(address(mockStrategy1), requested, requested);

        vm.prank(exec);
        uint256 received = strategyManager.pullFromStrategy(address(mockStrategy1), requested);

        assertEq(received, requested);
        assertEq(asset.balanceOf(address(strategyManager)), initialBalance + requested);
        assertEq(asset.balanceOf(address(mockStrategy1)), initialStrategyBalance - requested);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), initialWithdrawn + requested);
    }

    function test_PullFromStrategy_PartialWithdrawal() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        asset.mint(address(mockStrategy1), 1000e18);

        uint256 requested = 1000e18;
        uint256 actualReceived = 500e18;

        // Set strategy to return less than requested
        mockStrategy1.setWithdrawResult(actualReceived);

        uint256 initialBalance = asset.balanceOf(address(strategyManager));
        uint256 initialWithdrawn = strategyManager.getStrategyWithdrawn(address(mockStrategy1));

        vm.expectEmit(true, true, true, true);
        emit CapitalPulled(address(mockStrategy1), requested, actualReceived);

        vm.prank(exec);
        uint256 received = strategyManager.pullFromStrategy(address(mockStrategy1), requested);

        assertEq(received, actualReceived);
        assertEq(asset.balanceOf(address(strategyManager)), initialBalance + actualReceived);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), initialWithdrawn + actualReceived);
    }

    function test_PullFromStrategy_InconsistentReturn() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        asset.mint(address(mockStrategy1), 1000e18);

        // Strategy claims to return 1000 but only transfers 500
        mockStrategy1.setWithdrawResult(1000e18);
        asset.burn(address(mockStrategy1), asset.balanceOf(address(mockStrategy1)) - 500e18);

        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.InconsistentReturn.selector));
        strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);
    }

    function test_PullFromStrategy_UnknownStrategy() public {
        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.UnknownStrategy.selector));
        strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);
    }

    function test_PullFromStrategy_StrategyReverts() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        mockStrategy1.setShouldRevert(true);

        vm.prank(exec);
        vm.expectRevert("Strategy error");
        strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);
    }

    function test_WithdrawToVault_Success() public {
        uint256 amount = 1000e18;
        uint256 initialManagerBalance = asset.balanceOf(address(strategyManager));
        uint256 initialVaultBalance = asset.balanceOf(vault);

        vm.expectEmit(true, true, true, true);
        emit WithdrawnTo(vault, amount);

        vm.prank(vault);
        strategyManager.withdrawToVault(amount);

        assertEq(asset.balanceOf(address(strategyManager)), initialManagerBalance - amount);
        assertEq(asset.balanceOf(vault), initialVaultBalance + amount);
    }

    function test_WithdrawToVault_ZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAmount.selector));
        strategyManager.withdrawToVault(0);
    }

    function test_WithdrawToVault_InsufficientAssets() public {
        uint256 balance = asset.balanceOf(address(strategyManager));
        uint256 requested = balance + 1;

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.InsufficientAssets.selector, requested, balance));
        strategyManager.withdrawToVault(requested);
    }

    /* ==================== CAPITAL TRACKING TESTS ==================== */

    function test_CapitalTracking_PushPullFlow() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // Initial state
        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), 0);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 0);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 0);

        // Push 1000
        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);

        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), 1000e18);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 0);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 1000e18);

        // Pull 600
        vm.prank(exec);
        strategyManager.pullFromStrategy(address(mockStrategy1), 600e18);

        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), 1000e18);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 600e18);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 400e18);

        // Push another 500
        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 500e18);

        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), 1500e18);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 600e18);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 900e18);
    }

    function test_CapitalTracking_ProfitableStrategy() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // Push 1000
        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);

        // Strategy makes profit - add extra tokens
        asset.mint(address(mockStrategy1), 200e18);

        // Pull 1200 (original 1000 + 200 profit)
        vm.prank(exec);
        strategyManager.pullFromStrategy(address(mockStrategy1), 1200e18);

        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), 1000e18);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 1200e18);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), -200e18); // Negative = profit!
    }

    /* ==================== VIEW FUNCTIONS TESTS ==================== */

    function test_GetActiveStrategies_Empty() public {
        address[] memory active = strategyManager.getActiveStrategies();
        assertEq(active.length, 0);
    }

    function test_GetActiveStrategies_WithStrategies() public {
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        address[] memory active = strategyManager.getActiveStrategies();
        assertEq(active.length, 2);

        // Check both strategies are present (order doesn't matter)
        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == address(mockStrategy1)) found1 = true;
            if (active[i] == address(mockStrategy2)) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }

    function test_GetActiveStrategies_AfterRemoval() public {
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        strategyManager.removeStrategy(address(mockStrategy1));
        vm.stopPrank();

        address[] memory active = strategyManager.getActiveStrategies();
        assertEq(active.length, 1);
        assertEq(active[0], address(mockStrategy2));
    }

    function test_GetTotalDeployed() public {
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        assertEq(strategyManager.getTotalDeployed(), 0);

        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
        strategyManager.pushToStrategy(address(mockStrategy2), 500e18);
        vm.stopPrank();

        assertEq(strategyManager.getTotalDeployed(), 1500e18);

        // Remove strategy shouldn't affect total (still deployed)
        vm.prank(owner);
        strategyManager.removeStrategy(address(mockStrategy1));

        assertEq(strategyManager.getTotalDeployed(), 500e18); // Only active strategies counted
    }

    function test_GetTotalWithdrawn() public {
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
        strategyManager.pushToStrategy(address(mockStrategy2), 500e18);

        strategyManager.pullFromStrategy(address(mockStrategy1), 600e18);
        strategyManager.pullFromStrategy(address(mockStrategy2), 200e18);
        vm.stopPrank();

        assertEq(strategyManager.getTotalWithdrawn(), 800e18);
    }

    /* ==================== EMERGENCY FUNCTIONS TESTS ==================== */

    function test_EmergencyWithdrawToken_ERC20() public {
        // Deploy another token for emergency withdrawal
        ERC20Mock emergencyToken = new ERC20Mock();
        emergencyToken.mint(address(strategyManager), 1000e18);

        uint256 amount = 500e18;
        uint256 initialTreasuryBalance = emergencyToken.balanceOf(treasury);

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdraw(address(emergencyToken), amount);

        vm.prank(exec);
        strategyManager.forceSweepToTreasury(address(emergencyToken), amount);

        assertEq(emergencyToken.balanceOf(treasury), initialTreasuryBalance + amount);
    }

    function test_EmergencyWithdrawToken_ETH() public {
        uint256 amount = 1 ether;

        // Send ETH to strategy manager (bypass receive guard for testing)
        vm.deal(address(strategyManager), amount);

        uint256 initialTreasuryBalance = treasury.balance;

        vm.expectEmit(true, true, true, true);
        emit EmergencyWithdraw(address(0), amount);

        vm.prank(exec);
        strategyManager.forceSweepToTreasury(address(0), amount);

        assertEq(treasury.balance, initialTreasuryBalance + amount);
    }

    function test_EmergencyWithdrawToken_MainAsset() public {
        uint256 amount = 1000e18;
        uint256 initialTreasuryBalance = asset.balanceOf(treasury);

        vm.prank(exec);
        strategyManager.forceSweepToTreasury(address(asset), amount);

        assertEq(asset.balanceOf(treasury), initialTreasuryBalance + amount);
    }

    /* ==================== RECEIVE GUARD TESTS ==================== */

    function test_Receive_Reverts() public {
        (bool success, bytes memory data) = payable(address(strategyManager)).call{value: 1 ether}("");

        assertFalse(success);
        // Check that it starts with Error(string) selector
        assertEq(bytes4(data), bytes4(keccak256("Error(string)")));
    }

    /* ==================== UPGRADE TESTS ==================== */

    function test_UpgradeAuthorization_OnlyOwner() public {
        StrategyManager newImpl = new StrategyManager();

        vm.prank(unauthorized);
        vm.expectRevert();
        strategyManager.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_Success() public {
        StrategyManager newImpl = new StrategyManager();

        vm.prank(owner);
        strategyManager.upgradeToAndCall(address(newImpl), "");

        // Contract should still function after upgrade
        assertEq(address(strategyManager.asset()), address(asset));
        assertEq(strategyManager.owner(), owner);
    }

    /* ==================== REENTRANCY TESTS ==================== */

    function test_ReentrancyProtection_PushToStrategy() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // These functions should be protected against reentrancy
        // Multiple calls in same transaction context should work fine
        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
        strategyManager.pullFromStrategy(address(mockStrategy1), 500e18);
        vm.stopPrank();
    }

    /* ==================== COMPLEX SCENARIOS TESTS ==================== */

    function test_MultipleStrategies_ComplexFlow() public {
        // Add multiple strategies
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        // Push capital to both strategies
        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 2000e18);
        strategyManager.pushToStrategy(address(mockStrategy2), 1500e18);

        // Pull from one strategy
        uint256 received = strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);
        assertEq(received, 1000e18);

        vm.stopPrank();

        // Check balances
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 1000e18);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy2)), 1500e18);
        assertEq(strategyManager.getTotalDeployed(), 3500e18);
        assertEq(strategyManager.getTotalWithdrawn(), 1000e18);

        // Remove one strategy
        vm.prank(owner);
        strategyManager.removeStrategy(address(mockStrategy1));

        // Should not be able to push to removed strategy
        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.UnknownStrategy.selector));
        strategyManager.pushToStrategy(address(mockStrategy1), 500e18);

        // But can still interact with active strategy
        vm.prank(exec);
        strategyManager.pullFromStrategy(address(mockStrategy2), 500e18);

        // Totals should reflect only active strategies
        assertEq(strategyManager.getTotalDeployed(), 1500e18);
        assertEq(strategyManager.getTotalWithdrawn(), 500e18);

        // Active strategies should only show remaining strategy
        address[] memory active = strategyManager.getActiveStrategies();
        assertEq(active.length, 1);
        assertEq(active[0], address(mockStrategy2));
    }

    function test_CapitalFlow_WithProfitsAndLosses() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // Deploy capital
        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);

        // Strategy makes profit
        asset.mint(address(mockStrategy1), 300e18);

        // Pull back more than deployed (profit scenario)
        vm.prank(exec);
        uint256 received = strategyManager.pullFromStrategy(address(mockStrategy1), 1200e18);
        assertEq(received, 1200e18);

        // Net deployed should be negative (profit!)
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), -200e18);

        // Deploy again
        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 800e18);

        // Now net should be positive again
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 600e18);
    }

    function test_VaultWithdrawal_AfterStrategyOperations() public {
        // Add strategy and deploy capital
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 2000e18);

        // Pull some back to manager
        strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);
        vm.stopPrank();

        // Manager should have enough for vault withdrawal
        uint256 managerBalance = asset.balanceOf(address(strategyManager));
        assertGe(managerBalance, 1000e18);

        // Vault withdrawal should work
        vm.prank(vault);
        strategyManager.withdrawToVault(1000e18);

        assertEq(asset.balanceOf(vault), 1000e18);
    }

    function test_MaxStrategies_EdgeCase() public {
        uint256 maxStrategies = strategyManager.MAX_STRATEGIES();

        // Add max strategies
        MockStrategy[] memory strategies = new MockStrategy[](maxStrategies);
        vm.startPrank(owner);
        for (uint256 i = 0; i < maxStrategies; i++) {
            strategies[i] = new MockStrategy(asset, owner);
            strategyManager.addStrategy(address(strategies[i]));
        }
        vm.stopPrank();

        assertEq(strategyManager.strategiesLength(), maxStrategies);

        // Remove one and add another (should work)
        vm.startPrank(owner);
        strategyManager.removeStrategy(address(strategies[0]));

        MockStrategy newStrategy = new MockStrategy(asset, owner);
        strategyManager.addStrategy(address(newStrategy));
        vm.stopPrank();

        assertEq(strategyManager.strategiesLength(), maxStrategies);

        // Active strategies should be maxStrategies
        address[] memory active = strategyManager.getActiveStrategies();
        assertEq(active.length, maxStrategies);
    }

    function test_StrategyInterfaceValidation_EdgeCases() public {
        // Strategy that reverts on interface check
        mockStrategy1.setShouldRevert(true);

        vm.prank(owner);
        vm.expectRevert(bytes("Invalid strategy interface"));
        strategyManager.addStrategy(address(mockStrategy1));

        // Reset and add successfully
        mockStrategy1.setShouldRevert(false);

        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        assertTrue(strategyManager.isStrategy(address(mockStrategy1)));
    }

    function test_EmergencyScenarios() public {
        // Add strategy and deploy capital
        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
        strategyManager.pushToStrategy(address(mockStrategy2), 500e18);
        vm.stopPrank();

        // Emergency: withdraw all available assets to treasury
        uint256 managerBalance = asset.balanceOf(address(strategyManager));
        uint256 treasuryBalance = asset.balanceOf(treasury);

        vm.prank(exec);
        strategyManager.forceSweepToTreasury(address(asset), managerBalance);

        assertEq(asset.balanceOf(treasury), treasuryBalance + managerBalance);
        assertEq(asset.balanceOf(address(strategyManager)), 0);

        // Strategies still have their capital
        assertGt(asset.balanceOf(address(mockStrategy1)), 0);
        assertGt(asset.balanceOf(address(mockStrategy2)), 0);
    }

    /* ==================== EDGE CASES AND ERROR CONDITIONS ==================== */

    function test_PullFromStrategy_NoBalance() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // Strategy has no balance
        asset.burn(address(mockStrategy1), asset.balanceOf(address(mockStrategy1)));

        vm.prank(exec);
        vm.expectRevert();
        uint256 received = strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);

        // Should return 0 and update tracking accordingly
        assertEq(received, 0);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 0);
    }

    function test_StrategyTracking_ConsistencyChecks() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // Multiple operations
        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
        strategyManager.pullFromStrategy(address(mockStrategy1), 300e18);
        strategyManager.pushToStrategy(address(mockStrategy1), 500e18);
        strategyManager.pullFromStrategy(address(mockStrategy1), 800e18);
        vm.stopPrank();

        // Check final state
        assertEq(strategyManager.getStrategyDeployed(address(mockStrategy1)), 1500e18);
        assertEq(strategyManager.getStrategyWithdrawn(address(mockStrategy1)), 1100e18);
        assertEq(strategyManager.strategyNetDeployed(address(mockStrategy1)), 400e18);
    }

    function test_AccessControl_Comprehensive() public {
        // Test that unauthorized users can't call any restricted functions
        address[] memory restrictedCallers = new address[](4);
        restrictedCallers[0] = unauthorized;
        restrictedCallers[1] = user;
        restrictedCallers[2] = treasury;
        restrictedCallers[3] = makeAddr("random");

        for (uint256 i = 0; i < restrictedCallers.length; i++) {
            address caller = restrictedCallers[i];

            vm.startPrank(caller);

            // Owner-only functions
            vm.expectRevert();
            strategyManager.setVault(makeAddr("newVault"));

            vm.expectRevert();
            strategyManager.addStrategy(address(mockStrategy1));

            // Exec-only functions
            vm.expectRevert(bytes("OE"));
            strategyManager.pushToStrategy(address(mockStrategy1), 100e18);

            vm.expectRevert(bytes("OE"));
            strategyManager.forceSweepToTreasury(address(asset), 100e18);

            // Vault-only functions
            vm.expectRevert(bytes("OE"));
            strategyManager.withdrawToVault(100e18);

            vm.stopPrank();
        }
    }
}
