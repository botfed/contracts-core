// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pausable4626Vault} from "../src/Pausable4626Vault.sol";
import {StrategyManager} from "../src/StrategyManager.sol";
import {WithdrawRequestNFT} from "../src/WithdrawRequestNFT.sol";

// Mock WETH contract for testing
contract MockWETH is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

// Mock Strategy Manager for testing
contract MockStrategyManager {
    IERC20 public asset;
    address public vault;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    function withdrawToVault(uint256 amount) external {
        // Simulate providing liquidity back to vault
        asset.transfer(vault, amount);
    }
}

contract Pausable4626VaultTest is Test {
    Pausable4626Vault public vault;
    Pausable4626Vault public vaultImpl;
    MockWETH public weth;
    MockStrategyManager public strategyManager;
    WithdrawRequestNFT public withdrawNFT;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public fulfiller = makeAddr("fulfiller");
    address public treasury = makeAddr("treasury");
    address public exec = makeAddr("exec");

    uint256 constant INITIAL_WETH = 100 ether;

    function setUp() public {
        // Deploy mock WETH
        weth = new MockWETH();

        // Deploy mock strategy manager
        strategyManager = new MockStrategyManager(weth);

        // Deploy vault implementation
        vaultImpl = new Pausable4626Vault();

        // Deploy vault proxy
        bytes memory initData = abi.encodeWithSelector(
            Pausable4626Vault.initialize.selector,
            address(weth),
            "BotFed ETH Vault",
            "botETH",
            owner,
            address(strategyManager),
            fulfiller
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = Pausable4626Vault(payable(address(proxy)));

        // Set vault in strategy manager
        vm.prank(owner);
        strategyManager.setVault(address(vault));

        // Get withdrawNFT reference
        withdrawNFT = vault.withdrawNFT();

        // Mint WETH to users
        weth.mint(user1, INITIAL_WETH);
        weth.mint(user2, INITIAL_WETH);
        weth.mint(address(strategyManager), INITIAL_WETH); // For withdrawal liquidity
    }

    // ============ INITIALIZATION TESTS ============

    function test_Initialization() public {
        assertEq(address(vault.asset()), address(weth));
        assertEq(vault.name(), "BotFed ETH Vault");
        assertEq(vault.symbol(), "botETH");
        assertEq(vault.owner(), owner);
        assertEq(address(vault.manager()), address(strategyManager));
        assertEq(vault.fulfiller(), fulfiller);
        assertFalse(vault.paused());
    }

    function test_InitializationOnlyOnce() public {
        vm.expectRevert();
        vault.initialize(
            weth,
            "Test",
            "TEST",
            owner,
            address(strategyManager),
            fulfiller
        );
    }

    // ============ DEPOSIT TESTS ============

    function test_Deposit() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(user1);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        vm.stopPrank();

        // Check 1:1 conversion
        assertEq(shares, depositAmount);
        assertEq(vault.balanceOf(user1), depositAmount);
        assertEq(vault.totalSupply(), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);

        // Check WETH was transferred to strategy manager
        assertEq(
            weth.balanceOf(address(strategyManager)),
            INITIAL_WETH + depositAmount
        );
        assertEq(weth.balanceOf(user1), INITIAL_WETH - depositAmount);
    }

    function test_DepositRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vm.expectRevert();
        vault.deposit(10 ether, user1);
        vm.stopPrank();
    }

    function test_DepositRevertsWithoutManagerSet() public {
        // Deploy new vault without manager
        bytes memory initData = abi.encodeWithSelector(
            Pausable4626Vault.initialize.selector,
            address(weth),
            "Test Vault",
            "TEST",
            owner,
            address(0), // No manager
            fulfiller
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        Pausable4626Vault newVault = Pausable4626Vault(payable(address(proxy)));

        vm.startPrank(user1);
        weth.approve(address(newVault), 10 ether);
        vm.expectRevert(bytes("manager not set"));
        newVault.deposit(10 ether, user1);
        vm.stopPrank();
    }

    // ============ CONVERSION TESTS ============

    function test_ConversionsAre1to1() public {
        assertEq(vault.convertToShares(1 ether), 1 ether);
        assertEq(vault.convertToAssets(1 ether), 1 ether);
        assertEq(vault.previewDeposit(1 ether), 1 ether);
        assertEq(vault.previewMint(1 ether), 1 ether);
        assertEq(vault.previewWithdraw(1 ether), 1 ether);
        assertEq(vault.previewRedeem(1 ether), 1 ether);
    }

    function test_TotalAssetsEqualsTotalSupply() public {
        // Initially zero
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);

        // After deposits
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 10 ether);
        assertEq(vault.totalSupply(), 10 ether);

        // After second deposit
        vm.startPrank(user2);
        weth.approve(address(vault), 5 ether);
        vault.deposit(5 ether, user2);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 15 ether);
        assertEq(vault.totalSupply(), 15 ether);
    }

    // ============ DISABLED FUNCTIONS TESTS ============

    function test_DirectWithdrawRedeem_Disabled() public {
        assertEq(vault.maxWithdraw(user1), 0);
        assertEq(vault.maxRedeem(user1), 0);
        assertEq(vault.maxMint(user1), 0);

        vm.expectRevert();
        vault.mint(1 ether, user1);

        vm.expectRevert();
        vault.withdraw(1 ether, user1, user1);

        vm.expectRevert();
        vault.redeem(1 ether, user1, user1);
    }

    // ============ WITHDRAWAL REQUEST TESTS ============

    function test_RequestWithdrawAssets() public {
        // First deposit
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);

        // Approve vault to spend shares for withdrawal request
        vault.approve(address(vault), 5 ether);

        // Request withdrawal
        (uint256 requestId, uint256 shares) = vault.requestWithdrawAssets(
            5 ether,
            user1
        );
        vm.stopPrank();

        assertEq(requestId, 1);
        assertEq(shares, 5 ether);

        // Check request details
        (
            uint128 reqShares,
            address receiver,
            address reqOwner,
            bool settled,
            bool claimed
        ) = vault.requests(requestId);

        assertEq(reqShares, 5 ether);
        assertEq(receiver, user1);
        assertEq(reqOwner, user1);
        assertFalse(settled);
        assertFalse(claimed);

        // Check shares are escrowed
        assertEq(vault.balanceOf(user1), 5 ether); // Remaining shares
        assertEq(vault.balanceOf(address(vault)), 5 ether); // Escrowed shares

        // Check NFT was minted
        assertEq(withdrawNFT.ownerOf(requestId), user1);
    }

    function test_RequestWithdrawAssets_RevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert();
        vault.requestWithdrawAssets(1 ether, user1);
    }

    function test_RequestWithdrawAssets_DifferentReceiver() public {
        // First deposit
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);

        // Request withdrawal with different receiver
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user2);
        vm.stopPrank();

        // Check request details
        (, address receiver, address reqOwner, , ) = vault.requests(requestId);
        assertEq(receiver, user2); // Different receiver
        assertEq(reqOwner, user1); // Original owner
    }

    // ============ FULFILLMENT TESTS ============

    function test_FulfillRequest() public {
        // Setup: user deposits and requests withdrawal
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        // Fulfiller fulfills the request
        vm.prank(fulfiller);
        uint256 assetsOut = vault.fulfillRequest(requestId);

        assertEq(assetsOut, 5 ether);

        // Check request is marked as settled
        (, , , bool settled, ) = vault.requests(requestId);
        assertTrue(settled);

        // Check vault has sufficient WETH (pulled from strategy manager)
        assertGe(weth.balanceOf(address(vault)), 5 ether);
    }

    function test_FulfillRequest_RevertsWhenPaused() public {
        // Setup request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        // Pause vault
        vm.prank(owner);
        vault.pause();

        // Fulfillment should revert
        vm.prank(fulfiller);
        vm.expectRevert();
        vault.fulfillRequest(requestId);
    }

    function test_FulfillRequest_OnlyFulfiller() public {
        // Setup request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        // Non-fulfiller should fail
        vm.prank(user2);
        vm.expectRevert(bytes("OF"));
        vault.fulfillRequest(requestId);
    }

    function test_FulfillRequest_AlreadySettled() public {
        // Setup and fulfill request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Try to fulfill again
        vm.prank(fulfiller);
        vm.expectRevert(bytes("settled"));
        vault.fulfillRequest(requestId);
    }

    // ============ CLAIM TESTS ============

    function test_ClaimWithdraw() public {
        // Setup: deposit, request, fulfill
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        uint256 balanceBefore = weth.balanceOf(user1);

        // User claims withdrawal
        vm.prank(user1);
        vault.claimWithdraw(requestId);

        // Check WETH was transferred to user
        assertEq(weth.balanceOf(user1), balanceBefore + 5 ether);

        // Check shares were burned
        assertEq(vault.totalSupply(), 5 ether); // Started with 10, burned 5

        // Check request is marked claimed
        (, , , , bool claimed) = vault.requests(requestId);
        assertTrue(claimed);

        // Check NFT was burned
        vm.expectRevert();
        withdrawNFT.ownerOf(requestId);
    }

    function test_ClaimWithdraw_RevertsWhenPaused() public {
        // Setup fulfilled request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Pause vault
        vm.prank(owner);
        vault.pause();

        // Claim should revert
        vm.prank(user1);
        vm.expectRevert();
        vault.claimWithdraw(requestId);
    }

    function test_ClaimWithdraw_OnlyOwner() public {
        // Setup fulfilled request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Wrong user tries to claim
        vm.prank(user2);
        vm.expectRevert(bytes("CWO"));
        vault.claimWithdraw(requestId);
    }

    function test_ClaimWithdraw_NotSettled() public {
        // Setup request but don't fulfill
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        // Try to claim before fulfillment
        vm.prank(user1);
        vm.expectRevert(bytes("CWS"));
        vault.claimWithdraw(requestId);
    }

    function test_ClaimWithdraw_AlreadyClaimed() public {
        // Setup and claim
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId, ) = vault.requestWithdrawAssets(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        vm.prank(user1);
        vault.claimWithdraw(requestId);

        // Try to claim again
        vm.prank(user1);
        vm.expectRevert(bytes("CWC"));
        vault.claimWithdraw(requestId);
    }

    // ============ ADMIN TESTS ============

    function test_SetManager_OnlyOwnerWhenPaused() public {
        MockStrategyManager newManager = new MockStrategyManager(weth);

        // Should fail when not paused
        vm.prank(owner);
        vm.expectRevert();
        vault.setManager(address(newManager));

        // Should work when paused
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.setManager(address(newManager));

        assertEq(address(vault.manager()), address(newManager));
    }

    function test_SetFulfiller_OnlyOwner() public {
        address newFulfiller = makeAddr("newFulfiller");

        vm.prank(owner);
        vault.setFulFiller(newFulfiller);

        assertEq(vault.fulfiller(), newFulfiller);

        // Non-owner should fail
        vm.prank(user1);
        vm.expectRevert();
        vault.setFulFiller(newFulfiller);
    }

    function test_PauseUnpause_OnlyOwner() public {
        // Pause
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        // Unpause
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());

        // Non-owner should fail
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }

    // ============ EMERGENCY TESTS ============

    function test_WithdrawToGov_OnlyOwner() public {
        // Send some WETH to vault
        weth.mint(address(vault), 1 ether);

        uint256 balanceBefore = weth.balanceOf(owner);

        vm.prank(owner);
        vault.withdrawToGov(address(weth), 1 ether);

        assertEq(weth.balanceOf(owner), balanceBefore + 1 ether);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_WithdrawToGov_NonOwnerReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdrawToGov(address(weth), 1 ether);
    }

    // ============ EDGE CASES ============

    function test_DepositZeroAmount() public {
        vm.startPrank(user1);
        weth.approve(address(vault), 0);
        uint256 shares = vault.deposit(0, user1);
        vm.stopPrank();

        assertEq(shares, 0);
        assertEq(vault.balanceOf(user1), 0);
    }

    function test_MultipleUsersDepositsAndWithdrawals() public {
        // User1 deposits
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        weth.approve(address(vault), 5 ether);
        vault.deposit(5 ether, user2);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 15 ether);
        assertEq(vault.balanceOf(user1), 10 ether);
        assertEq(vault.balanceOf(user2), 5 ether);
        assertEq(weth.balanceOf(address(vault)), 0);

        // User1 requests partial withdrawal
        vm.startPrank(user1);
        vault.approve(address(vault), 3 ether);
        (uint256 requestId1, ) = vault.requestWithdrawAssets(3 ether, user1);
        vm.stopPrank();

        // User2 requests full withdrawal
        vm.startPrank(user2);
        vault.approve(address(vault), 5 ether);
        (uint256 requestId2, ) = vault.requestWithdrawAssets(5 ether, user2);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(vault)), 0);

        // Fulfill both requests
        vm.prank(fulfiller);
        vault.fulfillRequest(requestId1);
        assertEq(weth.balanceOf(address(vault)), 3 ether);

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId2);

        assertEq(weth.balanceOf(address(vault)), 8 ether);

        // Claim both withdrawals
        vm.prank(user1);
        vault.claimWithdraw(requestId1);

        vm.prank(user2);
        vault.claimWithdraw(requestId2);
        assertEq(weth.balanceOf(address(vault)), 0 ether);

        // Check final state
        assertEq(vault.totalSupply(), 7 ether); // 15 - 3 - 5
        assertEq(vault.balanceOf(user1), 7 ether); // 10 - 3
        assertEq(vault.balanceOf(user2), 0 ether); // 5 - 5
    }
}
