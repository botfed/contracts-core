// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import "../src/StrategyBase.sol";

/*//////////////////////////////////////////////////////////////
                        CONCRETE STRATEGY
//////////////////////////////////////////////////////////////*/

contract TestStrategy is StrategyBaseUpgradeable {
    // no extra logic; inherits everything from StrategyBaseUpgradeable
}

contract TestStrategyV2 is StrategyBaseUpgradeable {
    // Example upgrade: add a trivial getter to verify upgrade succeeded
    function version() external pure returns (uint256) {
        return 2;
    }
}

/*//////////////////////////////////////////////////////////////
                              TESTS
//////////////////////////////////////////////////////////////*/

contract StrategyBaseUpgradeableTest is Test {
    TestStrategy public implementation;
    StrategyBaseUpgradeable public strategy; // proxy as StrategyBaseUpgradeable
    ERC20Mock public asset;

    address public owner      = makeAddr("owner");
    address public manager    = makeAddr("manager");
    address public executor   = makeAddr("executor");
    address public riskAdmin  = makeAddr("riskAdmin");
    address public rando      = makeAddr("rando");

    event ManagerSet(address indexed oldManager, address indexed newManager);
    event RiskAdminSet(address indexed oldRiskAdmin, address indexed newRiskAdmin);
    event ExecutorSet(address indexed oldExec, address indexed newExec);
    event Withdrawn(address indexed to, uint256 amount);

    function setUp() public {
        // Token
        asset = new ERC20Mock();

        // Implementation
        implementation = new TestStrategy();

        // Proxy init data (initialize(owner, manager, riskAdmin, executor, asset))
        bytes memory initData = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            owner,
            manager,
            riskAdmin,
            executor,
            IERC20(address(asset))
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        strategy = StrategyBaseUpgradeable(payable(address(proxy)));

        // Fund the strategy with some tokens for withdrawal tests
        asset.mint(address(strategy), 10_000e18);
    }

    /* ==================== INITIALIZATION ==================== */

    function test_Initialize_State() public view {
        assertEq(address(strategy.asset()), address(asset));
        assertEq(strategy.manager(), manager);
        assertEq(strategy.executor(), executor);
        assertEq(strategy.riskAdmin(), riskAdmin);
        assertEq(strategy.owner(), owner);
    }

    function test_Initialize_Events_Emitted() public {
        // Fresh deploy to check events precisely
        TestStrategy impl = new TestStrategy();

        vm.expectEmit(true, true, false, true);
        emit RiskAdminSet(address(0), riskAdmin);
        vm.expectEmit(true, true, false, true);
        emit ManagerSet(address(0), manager);
        vm.expectEmit(true, true, false, true);
        emit ExecutorSet(address(0), executor);

        bytes memory data = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            owner,
            manager,
            riskAdmin,
            executor,
            IERC20(address(asset))
        );
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_Revert_ZeroAddress() public {
        TestStrategy impl = new TestStrategy();

        // Zero owner
        bytes memory d1 = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            address(0),
            manager,
            riskAdmin,
            executor,
            IERC20(address(asset))
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), d1);

        // Zero manager
        bytes memory d2 = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            owner,
            address(0),
            riskAdmin,
            executor,
            IERC20(address(asset))
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), d2);

        // Zero riskAdmin
        bytes memory d3 = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            owner,
            manager,
            address(0),
            executor,
            IERC20(address(asset))
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), d3);

        // Zero executor
        bytes memory d4 = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            owner,
            manager,
            riskAdmin,
            address(0),
            IERC20(address(asset))
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), d4);

        // Zero asset
        bytes memory d5 = abi.encodeWithSelector(
            StrategyBaseUpgradeable.initialize.selector,
            owner,
            manager,
            riskAdmin,
            executor,
            IERC20(address(0))
        );
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        new ERC1967Proxy(address(impl), d5);
    }

    /* ==================== ACCESS CONTROL ==================== */

    function test_OnlyOwner_setManager() public {
        address newManager = makeAddr("newManager");

        vm.prank(rando);
        vm.expectRevert(); // Ownable revert
        strategy.setManager(newManager);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ManagerSet(manager, newManager);
        strategy.setManager(newManager);

        assertEq(strategy.manager(), newManager);
    }

    function test_OnlyExecutorOrGov_setExecutor() public {
        address newExec = makeAddr("newExec");

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.NotAuth.selector));
        strategy.setExecutor(newExec);

        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit ExecutorSet(executor, newExec);
        strategy.setExecutor(newExec);
        assertEq(strategy.executor(), newExec);

        // Owner can rotate too
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ExecutorSet(newExec, executor);
        strategy.setExecutor(executor);
        assertEq(strategy.executor(), executor);
    }

    function test_OnlyRiskAdminOrGov_setRiskAdmin() public {
        address newRisk = makeAddr("newRisk");

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.NotAuth.selector));
        strategy.setRiskAdmin(newRisk);

        vm.prank(riskAdmin);
        vm.expectEmit(true, true, false, true);
        emit RiskAdminSet(riskAdmin, newRisk);
        strategy.setRiskAdmin(newRisk);
        assertEq(strategy.riskAdmin(), newRisk);

        // Owner can rotate too
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RiskAdminSet(newRisk, riskAdmin);
        strategy.setRiskAdmin(riskAdmin);
        assertEq(strategy.riskAdmin(), riskAdmin);
    }

    function test_Setters_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        strategy.setManager(address(0));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        strategy.setExecutor(address(0));

        vm.prank(riskAdmin);
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.ZeroAddress.selector));
        strategy.setRiskAdmin(address(0));
    }

    /* ==================== WITHDRAWALS ==================== */

    function test_WithdrawToManager_ByManager_FullRequest() public {
        uint256 req = 1000e18;
        uint256 balBefore = asset.balanceOf(address(strategy));
        uint256 mgrBefore = asset.balanceOf(manager);

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(manager, req);
        uint256 withdrawn = strategy.withdrawToManager(req);

        assertEq(withdrawn, req);
        assertEq(asset.balanceOf(address(strategy)), balBefore - req);
        assertEq(asset.balanceOf(manager), mgrBefore + req);
    }

    function test_WithdrawToManager_ByOwner_FullRequest() public {
        uint256 req = 500e18;

        vm.prank(owner);
        uint256 withdrawn = strategy.withdrawToManager(req);
        assertEq(withdrawn, req);
    }

    function test_WithdrawToManager_PartialWhenInsufficientBalance() public {
        // Burn strategy tokens so it has less than requested
        uint256 bal = asset.balanceOf(address(strategy)); // 10_000e18 from setUp
        asset.burn(address(strategy), bal - 200e18); // leave only 200e18

        uint256 req = 1_000e18;
        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(manager, 200e18);
        uint256 withdrawn = strategy.withdrawToManager(req);

        assertEq(withdrawn, 200e18);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }

    function test_WithdrawToManager_ZeroRequest_Noop() public {
        uint256 stratBalBefore = asset.balanceOf(address(strategy));
        uint256 mgrBalBefore = asset.balanceOf(manager);

        vm.prank(manager);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(manager, 0);
        uint256 w = strategy.withdrawToManager(0);

        assertEq(w, 0);
        assertEq(asset.balanceOf(address(strategy)), stratBalBefore);
        assertEq(asset.balanceOf(manager), mgrBalBefore);
    }

    function test_WithdrawToManager_Unauthorized_Revert() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(StrategyBaseUpgradeable.NotAuth.selector));
        strategy.withdrawToManager(1);
    }

    /* ==================== ETH RECEIVE (current version allows ETH) ==================== */

    function test_Receive_AllowsETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = payable(address(strategy)).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(strategy).balance, 0.5 ether);
    }

    /* ==================== UPGRADEABILITY ==================== */

    function test_Upgrade_UUPS_OnlyOwner() public {
        TestStrategyV2 newImpl = new TestStrategyV2();

        vm.prank(rando);
        vm.expectRevert(); // Ownable: caller is not the owner
        strategy.upgradeToAndCall(address(newImpl), "");

        vm.prank(owner);
        strategy.upgradeToAndCall(address(newImpl), "");

        // Verify storage & behavior persist
        assertEq(address(strategy.asset()), address(asset));
        assertEq(strategy.manager(), manager);

        // Call the new function
        uint256 ver = TestStrategyV2(payable(address(strategy))).version();
        assertEq(ver, 2);
    }
}
