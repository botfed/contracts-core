// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Pausable4626Vault} from "../src/Pausable4626Vault.sol";
import {StrategyManager} from "../src/StrategyManager.sol";

// MockWETH - removed since vault no longer accepts ETH
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
        emit Transfer(address(0), to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        require(_balances[from] >= amount, "Insufficient balance");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
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

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public fulfiller = makeAddr("fulfiller");
    address public riskAdmin = makeAddr("riskAdmin");
    address public minter = makeAddr("minter");
    address public rewarder = makeAddr("rewarder");

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
            fulfiller,
            riskAdmin,
            minter,
            rewarder
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = Pausable4626Vault(payable(address(proxy)));

        vm.startPrank(riskAdmin);
        vault.setUserWhiteList(user1, true);
        vault.setUserWhiteList(user2, true);
        vm.stopPrank();

        // Set vault in strategy manager
        strategyManager.setVault(address(vault));

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
        vault.initialize(weth, "Test", "TEST", owner, address(strategyManager), fulfiller, riskAdmin, minter, rewarder);
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
        assertEq(weth.balanceOf(address(strategyManager)), INITIAL_WETH + depositAmount);
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
            fulfiller,
            riskAdmin,
            minter,
            rewarder
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        Pausable4626Vault newVault = Pausable4626Vault(payable(address(proxy)));

        vm.prank(riskAdmin);
        newVault.setUserWhiteList(user1, true);

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
        // First deposit so user has shares
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        vm.stopPrank();

        assertEq(vault.maxWithdraw(user1), 0);
        assertEq(vault.maxRedeem(user1), 10 ether); // ✅ FIXED: maxRedeem returns balance
        assertEq(vault.maxMint(user1), 0);

        vm.expectRevert(Pausable4626Vault.Disabled.selector); // ✅ FIXED: Use custom error
        vault.mint(1 ether, user1);

        vm.expectRevert(Pausable4626Vault.Disabled.selector);
        vault.withdraw(1 ether, user1, user1);

        vm.expectRevert(Pausable4626Vault.Disabled.selector);
        vault.redeem(1 ether, user1, user1);
    }

    // ============ WITHDRAWAL REQUEST TESTS ============
    
    function test_RequestWithdrawTooManyAssets() public {
        // First deposit
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);

        // Try to request more than balance
        vm.expectRevert(); // Will revert in _transfer due to insufficient balance
        vault.requestRedeem(15 ether, user1);
        vm.stopPrank();
    }

    function test_RequestWithdrawAssets() public {
        // First deposit
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);

        // Request withdrawal (no need to approve - it uses _spendAllowance internally)
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        assertEq(requestId, 1);

        // Check request details using getRequestStatus
        (bool exists, bool fulfilled, bool claimed, uint256 shares, uint256 assets) = vault.getRequestStatus(requestId);

        assertTrue(exists);
        assertFalse(fulfilled);
        assertFalse(claimed);
        assertEq(shares, 5 ether);
        assertEq(assets, 0); // Not fulfilled yet

        // Check shares are escrowed
        assertEq(vault.balanceOf(user1), 5 ether); // Remaining shares
        assertEq(vault.balanceOf(address(vault)), 5 ether); // Escrowed shares
    }

    function test_RequestWithdrawAssets_RevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert();
        vault.requestRedeem(1 ether, user1);
    }

    function test_RequestWithdrawAssets_DifferentReceiver() public {
        // First deposit
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);

        // Request withdrawal with different receiver
        uint256 requestId = vault.requestRedeem(5 ether, user2);
        vm.stopPrank();

        // Check request details via struct directly
        (uint256 amount, address receiver, address reqOwner,,,) = vault.requests(requestId);
        assertEq(receiver, user2); // Different receiver
        assertEq(reqOwner, user1); // Original owner
        assertEq(amount, 5 ether);
    }

    // ============ FULFILLMENT TESTS ============

    function test_FulfillRequest() public {
        // Setup: user deposits and requests withdrawal
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        // Fulfiller fulfills the request
        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Check request is marked as fulfilled
        (,bool fulfilled,,, uint256 assetsLocked) = vault.getRequestStatus(requestId);
        assertTrue(fulfilled);
        assertEq(assetsLocked, 5 ether);
        
        // Check vault has sufficient WETH (pulled from strategy manager)
        assertGe(weth.balanceOf(address(vault)), 5 ether);
    }

    function test_FulfillRequest_RevertsWhenPaused() public {
        // Setup request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
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
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        // Non-fulfiller should fail
        vm.prank(user2);
        vm.expectRevert(bytes("OF"));
        vault.fulfillRequest(requestId);
    }

    function test_FulfillRequest_AlreadyFulfilled() public {
        // Setup and fulfill request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Try to fulfill again
        vm.prank(fulfiller);
        vm.expectRevert(Pausable4626Vault.RequestAlreadyFulfilled.selector); // ✅ FIXED
        vault.fulfillRequest(requestId);
    }

    // ============ CLAIM TESTS ============

    function test_ClaimRedeem() public {
        // Setup: deposit, request, fulfill
        uint256 requestAmt = 5 ether;
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(requestAmt, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        uint256 balanceBefore = weth.balanceOf(user1);

        // User claims withdrawal
        vm.prank(user1);
        vault.claimRedemption(requestId);

        // Check WETH was transferred to user
        assertEq(weth.balanceOf(user1), balanceBefore + requestAmt);

        // Check shares were burned
        assertEq(vault.totalSupply(), 10 ether - requestAmt);

        // Check request has been deleted
        (bool exists,,,,) = vault.getRequestStatus(requestId);
        assertFalse(exists);
    }

    function test_ClaimRedeem_RevertsWhenPaused() public {
        // Setup fulfilled request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Pause vault
        vm.prank(owner);
        vault.pause();

        // Claim should revert
        vm.prank(user1);
        vm.expectRevert();
        vault.claimRedemption(requestId);
    }

    function test_ClaimRedeem_OnlyOwner() public {
        // Setup fulfilled request
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        // Wrong user tries to claim
        vm.prank(user2);
        vm.expectRevert(Pausable4626Vault.NotRequestOwner.selector); // ✅ FIXED
        vault.claimRedemption(requestId);
    }

    function test_ClaimRedeem_NotFulfilled() public {
        // Setup request but don't fulfill
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        // Try to claim before fulfillment
        vm.prank(user1);
        vm.expectRevert(Pausable4626Vault.RequestNotFulfilled.selector); // ✅ FIXED
        vault.claimRedemption(requestId);
    }

    function test_ClaimRedeem_AlreadyClaimed() public {
        // Setup and claim
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        vm.prank(user1);
        vault.claimRedemption(requestId);

        // Try to claim again - request no longer exists
        vm.prank(user1);
        vm.expectRevert(Pausable4626Vault.RequestDoesNotExist.selector); // ✅ FIXED
        vault.claimRedemption(requestId);
    }

    // ============ CANCEL REQUEST TESTS ============
    
    function test_CancelRequest() public {
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        
        // Cancel before fulfillment
        vault.cancelRequest(requestId);
        vm.stopPrank();

        // Shares returned
        assertEq(vault.balanceOf(user1), 10 ether);
        
        // Request deleted
        (bool exists,,,,) = vault.getRequestStatus(requestId);
        assertFalse(exists);
    }

    function test_CancelRequest_AfterFulfillmentReverts() public {
        vm.startPrank(user1);
        weth.approve(address(vault), 10 ether);
        vault.deposit(10 ether, user1);
        uint256 requestId = vault.requestRedeem(5 ether, user1);
        vm.stopPrank();

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId);

        vm.prank(user1);
        vm.expectRevert(Pausable4626Vault.RequestAlreadyFulfilled.selector);
        vault.cancelRequest(requestId);
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
        vault.setFulfiller(newFulfiller);

        assertEq(vault.fulfiller(), newFulfiller);

        // Non-owner should fail
        vm.prank(user1);
        vm.expectRevert();
        vault.setFulfiller(newFulfiller);
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

        // User1 requests partial withdrawal
        vm.startPrank(user1);
        uint256 requestId1 = vault.requestRedeem(3 ether, user1);
        vm.stopPrank();

        // User2 requests full withdrawal
        vm.startPrank(user2);
        uint256 requestId2 = vault.requestRedeem(5 ether, user2);
        vm.stopPrank();

        // Fulfill both requests
        vm.prank(fulfiller);
        vault.fulfillRequest(requestId1);

        vm.prank(fulfiller);
        vault.fulfillRequest(requestId2);

        // Claim both withdrawals
        vm.prank(user1);
        vault.claimRedemption(requestId1);

        vm.prank(user2);
        vault.claimRedemption(requestId2);

        // Check final state
        assertEq(vault.totalSupply(), 7 ether); // 15 - 3 - 5
        assertEq(vault.balanceOf(user1), 7 ether); // 10 - 3
        assertEq(vault.balanceOf(user2), 0 ether); // 5 - 5
    }

    // ============ WHITELIST TESTS ============
    
    function test_UserWhiteList() public {
        address user = makeAddr("testuser1");
        assertFalse(vault.userIsWhitelisted(user));
        
        vm.prank(riskAdmin);
        vault.setUserWhiteList(user, true);
        
        assertTrue(vault.userIsWhitelisted(user));
    }

    function test_UserWhiteListActive() public {
        vm.prank(riskAdmin);
        vault.setUserWhiteListActive(false);
        assertFalse(vault.userWhiteListActive());
    }
    
    function test_UserWhiteListActiveRevert() public {
        vm.prank(user1);
        vm.expectRevert(bytes("ORA"));
        vault.setUserWhiteListActive(false);
    }
    
    function test_RaiseTVLCap() public {
        vm.prank(riskAdmin);
        vault.setTVLCap(1000 ether);
        assertEq(vault.tvlCap(), 1000 ether);
    }
    
    function test_DepositMoreThanTVLCap() public {
        vm.startPrank(user1);
        weth.approve(address(vault), 1000 ether);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        vault.deposit(1000 ether, user1);
        vm.stopPrank();
    }
    
    function test_RaiseTVLCap_NoAUTH() public {
        vm.prank(user1);
        vm.expectRevert(bytes("ORA"));
        vault.setTVLCap(1000 ether);
    }
    
    // ============ REWARDS TESTS ============
    
    function test_Mint() public {
        uint256 bal0 = vault.balanceOf(rewarder);
        
        vm.prank(minter);
        vault.mintRewards(1000 ether);
        
        uint256 bal1 = vault.balanceOf(rewarder);
        assertEq(bal1 - bal0, 1000 ether);
    }
    
    function test_setMinter() public {
        vm.prank(owner);
        vault.pause();
        
        vm.prank(owner);
        vault.setMinter(makeAddr("newMinter"));
        
        assertEq(vault.minter(), makeAddr("newMinter"));
    }
    
    function test_setMinter_NoAuth() public {
        vm.prank(owner);
        vault.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        vault.setMinter(makeAddr("newMinter"));
    }
    
    function test_Mint_NoAUTH() public {
        vm.prank(user1);
        vm.expectRevert(bytes("OM"));
        vault.mintRewards(1000 ether);
    }
    
    function test_setRewarder() public {
        vm.prank(owner);
        vault.pause();
        
        vm.prank(owner);
        vault.setRewarder(makeAddr("newRewarder"));
        
        assertEq(vault.rewarder(), makeAddr("newRewarder"));
    }
    
    function test_setRewarder_NoAuth() public {
        vm.prank(owner);
        vault.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        vault.setRewarder(makeAddr("newRewarder"));
    }

    // NOTE: All ETH auto-deposit tests removed since vault no longer accepts ETH
}