// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import "../src/StrategyManager.sol";

/*//////////////////////////////////////////////////////////////
                       MOCK STRATEGIES
//////////////////////////////////////////////////////////////*/

contract MockStrategy {
    IERC20 public asset;
    address public owner;
    uint256 public withdrawResult = type(uint256).max; // Return full "requested" by default
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
        if (shouldRevert) revert("Strategy error");

        uint256 toReturn = withdrawResult == type(uint256).max ? requested : withdrawResult;
        uint256 bal = asset.balanceOf(address(this));
        if (toReturn > 0 && toReturn <= bal) {
            asset.transfer(msg.sender, toReturn);
        } else if (toReturn > bal && bal > 0) {
            asset.transfer(msg.sender, bal);
        }
        return toReturn;
    }

    // Allow receiving tokens
    receive() external payable {}
}

// No owner()/asset() views -> addStrategy should revert
contract BadMockStrategy {}

/*//////////////////////////////////////////////////////////////
                           TESTS
//////////////////////////////////////////////////////////////*/

contract StrategyManagerTest is Test {
    StrategyManager public strategyManager;
    StrategyManager public implementation;
    ERC20Mock public asset;
    MockStrategy public mockStrategy1;
    MockStrategy public mockStrategy2;
    BadMockStrategy public badStrategy;

    address public owner = makeAddr("owner");
    address public exec = makeAddr("exec");
    address public vault = makeAddr("vault");
    address public unauthorized = makeAddr("unauthorized");

    event StrategyAdded(address indexed strat);
    event StrategyRemoved(address indexed strat);
    event CapitalPushed(address indexed strat, uint256 amount);
    event CapitalPulled(address indexed strat, uint256 requested, uint256 received);
    event WithdrawnTo(address indexed to, uint256 amount);
    event SetVault(address indexed oldVault, address indexed newVault);
    event SetExec(address indexed oldExec, address indexed newExec);

    function setUp() public {
        // Deploy mock asset
        asset = new ERC20Mock();

        // Deploy implementation
        implementation = new StrategyManager();

        // Deploy proxy and initialize (note: final initialize is (asset, owner, exec))
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            IERC20(address(asset)),
            owner,
            exec
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        strategyManager = StrategyManager(payable(address(proxy)));

        // Set vault
        vm.prank(owner);
        strategyManager.setVault(vault);

        // Deploy strategies
        mockStrategy1 = new MockStrategy(asset, owner);
        mockStrategy2 = new MockStrategy(asset, owner);
        badStrategy = new BadMockStrategy();

        // Fund manager & strategies
        asset.mint(address(strategyManager), 10_000e18);
        asset.mint(address(mockStrategy1), 5_000e18);
        asset.mint(address(mockStrategy2), 5_000e18);
    }

    /* ==================== INITIALIZATION ==================== */

    function test_Initialize_Success() public {
        assertEq(address(strategyManager.asset()), address(asset));
        assertEq(strategyManager.owner(), owner);
        assertEq(strategyManager.exec(), exec);
        assertEq(strategyManager.vault(), vault);
    }

    function test_Initialize_ZeroAsset() public {
        StrategyManager newImpl = new StrategyManager();
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            IERC20(address(0)),
            owner,
            exec
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_ZeroOwner() public {
        StrategyManager newImpl = new StrategyManager();
        bytes memory initData = abi.encodeWithSelector(
            StrategyManager.initialize.selector,
            IERC20(address(asset)),
            address(0),
            exec
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAddress.selector));
        new ERC1967Proxy(address(newImpl), initData);
    }

    /* ==================== ACCESS CONTROL ==================== */

    function test_OnlyOwner_SetVault() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Ownable revert
        strategyManager.setVault(makeAddr("newVault"));
    }

    function test_OnlyOwner_SetExec() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Ownable revert
        strategyManager.setExec(makeAddr("newExec"));
    }

    function test_OnlyOwner_AddStrategy() public {
        vm.prank(unauthorized);
        vm.expectRevert(); // Ownable revert
        strategyManager.addStrategy(address(mockStrategy1));
    }

    function test_OnlyOwner_RemoveStrategy() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(unauthorized);
        vm.expectRevert(); // Ownable revert
        strategyManager.removeStrategy(address(mockStrategy1));
    }

    function test_OnlyExecOrOwner_PushToStrategy() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.OnlyExecOrOwner.selector));
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
    }

    function test_OnlyVault_WithdrawToVault() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.OnlyVault.selector));
        strategyManager.withdrawToVault(1000e18);
    }

    function test_Owner_CannotBypassVaultRestrictions() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.OnlyVault.selector));
        strategyManager.withdrawToVault(1000e18);
    }

    /* ==================== ADMIN SETTERS ==================== */

    function test_SetVault_Success() public {
        address oldVault = strategyManager.vault();
        address newVault = makeAddr("newVault");

        vm.expectEmit(true, true, true, true);
        emit SetVault(oldVault, newVault);

        vm.prank(owner);
        strategyManager.setVault(newVault);

        assertEq(strategyManager.vault(), newVault);
    }

    function test_SetVault_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAddress.selector));
        strategyManager.setVault(address(0));
    }

    function test_SetExec_Success() public {
        address oldExec = strategyManager.exec();
        address newExec = makeAddr("newExec");

        vm.expectEmit(true, true, true, true);
        emit SetExec(oldExec, newExec);

        vm.prank(owner);
        strategyManager.setExec(newExec);

        assertEq(strategyManager.exec(), newExec);
    }

    function test_SetExec_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAddress.selector));
        strategyManager.setExec(address(0));
    }

    /* ==================== STRATEGY MANAGEMENT ==================== */

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
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAddress.selector));
        strategyManager.addStrategy(address(0));
    }

    function test_AddStrategy_AlreadyExists() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.StrategyAlreadyExists.selector));
        strategyManager.addStrategy(address(mockStrategy1));
    }

    function test_AddStrategy_BadContract_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(); // owner()/asset() calls will fail
        strategyManager.addStrategy(address(badStrategy));
    }

    function test_AddStrategy_MaxStrategies() public {
        uint256 maxStrategies = strategyManager.MAX_STRATEGIES();

        vm.startPrank(owner);
        for (uint256 i = 0; i < maxStrategies; i++) {
            MockStrategy s = new MockStrategy(asset, owner);
            strategyManager.addStrategy(address(s));
        }
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.MaxStrategies.selector));
        strategyManager.addStrategy(address(mockStrategy1));
    }

    function test_RemoveStrategy_Success_And_BlockInteractions() public {
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

        // Cannot push/pull removed strategy
        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.UnknownStrategy.selector));
        strategyManager.pushToStrategy(address(mockStrategy1), 1);

        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.UnknownStrategy.selector));
        strategyManager.pullFromStrategy(address(mockStrategy1), 1);
    }

    function test_RemoveStrategy_NotExists() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.StrategyDoesNotExist.selector));
        strategyManager.removeStrategy(address(mockStrategy1));
    }

    /* ==================== CAPITAL MOVEMENT ==================== */

    function test_PushToStrategy_Success() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        uint256 amount = 1000e18;
        uint256 initialManagerBal = asset.balanceOf(address(strategyManager));
        uint256 initialStratBal = asset.balanceOf(address(mockStrategy1));
        uint256 initialDeployed = strategyManager.strategyDeployed(address(mockStrategy1));

        vm.expectEmit(true, true, true, true);
        emit CapitalPushed(address(mockStrategy1), amount);

        vm.prank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), amount);

        assertEq(asset.balanceOf(address(strategyManager)), initialManagerBal - amount);
        assertEq(asset.balanceOf(address(mockStrategy1)), initialStratBal + amount);
        assertEq(strategyManager.strategyDeployed(address(mockStrategy1)), initialDeployed + amount);
    }

    function test_PushToStrategy_UnknownStrategy() public {
        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.UnknownStrategy.selector));
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
    }

    function test_PushToStrategy_InsufficientBalance() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        uint256 bal = asset.balanceOf(address(strategyManager));

        vm.prank(exec);
        vm.expectRevert(); // SafeERC20 transfer revert
        strategyManager.pushToStrategy(address(mockStrategy1), bal + 1);
    }

    function test_PullFromStrategy_Success() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        asset.mint(address(mockStrategy1), 1000e18);

        uint256 requested = 500e18;
        uint256 initialManagerBal = asset.balanceOf(address(strategyManager));
        uint256 initialStratBal = asset.balanceOf(address(mockStrategy1));
        uint256 initialWithdrawn = strategyManager.strategyWithdrawn(address(mockStrategy1));

        vm.expectEmit(true, true, true, true);
        emit CapitalPulled(address(mockStrategy1), requested, requested);

        vm.prank(exec);
        uint256 received = strategyManager.pullFromStrategy(address(mockStrategy1), requested);

        assertEq(received, requested);
        assertEq(asset.balanceOf(address(strategyManager)), initialManagerBal + requested);
        assertEq(asset.balanceOf(address(mockStrategy1)), initialStratBal - requested);
        assertEq(strategyManager.strategyWithdrawn(address(mockStrategy1)), initialWithdrawn + requested);
    }

    function test_PullFromStrategy_PartialWithdrawal() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        asset.mint(address(mockStrategy1), 1000e18);

        uint256 requested = 1000e18;
        uint256 actualReceived = 500e18;
        mockStrategy1.setWithdrawResult(actualReceived);

        uint256 initialManagerBal = asset.balanceOf(address(strategyManager));
        uint256 initialWithdrawn = strategyManager.strategyWithdrawn(address(mockStrategy1));

        vm.expectEmit(true, true, true, true);
        emit CapitalPulled(address(mockStrategy1), requested, actualReceived);

        vm.prank(exec);
        uint256 recv = strategyManager.pullFromStrategy(address(mockStrategy1), requested);

        assertEq(recv, actualReceived);
        assertEq(asset.balanceOf(address(strategyManager)), initialManagerBal + actualReceived);
        assertEq(strategyManager.strategyWithdrawn(address(mockStrategy1)), initialWithdrawn + actualReceived);
    }

    function test_PullFromStrategy_InconsistentReturn() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        asset.mint(address(mockStrategy1), 1000e18);

        // Strategy claims 1000 but actually sends 500
        mockStrategy1.setWithdrawResult(1000e18);
        uint256 bal = asset.balanceOf(address(mockStrategy1));
        asset.burn(address(mockStrategy1), bal - 500e18);

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

    /* ==================== VAULT WITHDRAWALS ==================== */

    function test_WithdrawToVault_Success() public {
        uint256 amount = 1000e18;
        uint256 initialManagerBal = asset.balanceOf(address(strategyManager));
        uint256 initialVaultBal = asset.balanceOf(vault);

        vm.expectEmit(true, true, true, true);
        emit WithdrawnTo(vault, amount);

        vm.prank(vault);
        strategyManager.withdrawToVault(amount);

        assertEq(asset.balanceOf(address(strategyManager)), initialManagerBal - amount);
        assertEq(asset.balanceOf(vault), initialVaultBal + amount);
    }

    function test_WithdrawToVault_ZeroAmount() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.ZeroAmount.selector));
        strategyManager.withdrawToVault(0);
    }

    function test_WithdrawToVault_InsufficientAssets() public {
        uint256 bal = asset.balanceOf(address(strategyManager));
        uint256 req = bal + 1;

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.InsufficientAssets.selector, req, bal));
        strategyManager.withdrawToVault(req);
    }

    /* ==================== VIEWS ==================== */

    function test_StrategiesLength_Basics() public {
        assertEq(strategyManager.strategiesLength(), 0);

        vm.startPrank(owner);
        strategyManager.addStrategy(address(mockStrategy1));
        strategyManager.addStrategy(address(mockStrategy2));
        vm.stopPrank();

        assertEq(strategyManager.strategiesLength(), 2);
    }

    /* ==================== UPGRADEABILITY ==================== */

    function test_UpgradeAuthorization_OnlyOwner() public {
        StrategyManager newImpl = new StrategyManager();

        vm.prank(unauthorized);
        vm.expectRevert(); // Ownable revert inside _authorizeUpgrade
        strategyManager.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_Success() public {
        StrategyManager newImpl = new StrategyManager();

        vm.prank(owner);
        strategyManager.upgradeToAndCall(address(newImpl), "");

        // Still functional
        assertEq(address(strategyManager.asset()), address(asset));
        assertEq(strategyManager.owner(), owner);
    }

    /* ==================== REENTRANCY / HAPPY PATH ==================== */

    function test_ReentrancyProtection_PushThenPull() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        vm.startPrank(exec);
        strategyManager.pushToStrategy(address(mockStrategy1), 1000e18);
        strategyManager.pullFromStrategy(address(mockStrategy1), 500e18);
        vm.stopPrank();
    }

    /* ==================== EDGE BEHAVIOR ==================== */

    function test_PullFromStrategy_NoBalance_CausesInconsistentReturn() public {
        vm.prank(owner);
        strategyManager.addStrategy(address(mockStrategy1));

        // drain strategy to zero
        asset.burn(address(mockStrategy1), asset.balanceOf(address(mockStrategy1)));

        vm.prank(exec);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.InconsistentReturn.selector));
        strategyManager.pullFromStrategy(address(mockStrategy1), 1000e18);
    }
}
