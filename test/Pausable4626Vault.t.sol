// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Pausable4626Vault} from "../src/Pausable4626Vault.sol";

// ---------- Mocks ----------

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BAL");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ALLOW");
        require(balanceOf[from] >= amount, "BAL");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockStrategyManager {
    IERC20 public asset;
    address public vault;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    // Simulate synchronous liquidity return to the vault
    function withdrawToVault(uint256 amount) external {
        require(msg.sender == vault, "only vault");
        asset.transfer(vault, amount);
    }

    // Whatever the manager holds is withdrawable right now
    function maxWithdrawable() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

// ---------- Tests for new vault ----------

contract Pausable4626VaultTest is Test {
    Pausable4626Vault public vault;
    Pausable4626Vault public vaultImpl;
    MockERC20 public token; // e.g., USDC (6 decimals)
    MockStrategyManager public strategy;

    address public owner = makeAddr("owner");
    address public riskAdmin = makeAddr("riskAdmin"); // not directly used (riskAdmin starts as owner in new code)
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 constant INITIAL_TOKENS = 1_000_000_000; // 1e9 (interpreted with token.decimals)

    function setUp() public {
        // Underlying with 6 decimals to exercise decimals override
        token = new MockERC20("Mock USDC", "mUSDC", 6);

        // Strategy manager
        strategy = new MockStrategyManager(token);

        // Vault implementation
        vaultImpl = new Pausable4626Vault();

        // Proxy init
        bytes memory initData = abi.encodeWithSelector(
            Pausable4626Vault.initialize.selector,
            address(token),
            "BotFed USDC Vault",
            "botUSDC",
            owner,
            address(strategy)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = Pausable4626Vault(payable(address(proxy)));

        // Strategy needs to know the vault
        strategy.setVault(address(vault));

        // Whitelist users (riskAdmin defaults to owner in initialize)
        vm.prank(owner);
        vault.setUserWhiteList(user1, true);
        vm.prank(owner);
        vault.setUserWhiteList(user2, true);

        // Mint tokens to users and manager
        token.mint(user1, INITIAL_TOKENS);
        token.mint(user2, INITIAL_TOKENS);
        token.mint(address(strategy), INITIAL_TOKENS); // manager liquidity
    }

    // -------- Initialization --------

    function test_Init() public view {
        assertEq(address(vault.asset()), address(token));
        assertEq(vault.name(), "BotFed USDC Vault");
        assertEq(vault.symbol(), "botUSDC");
        assertEq(vault.owner(), owner);
        assertEq(address(vault.manager()), address(strategy));
        assertFalse(vault.paused());
        // shares decimals match underlying (6)
        assertEq(vault.decimals(), 6);
    }

    function test_SetManager_OnlyOwner_WhenPaused() public {
        MockStrategyManager s2 = new MockStrategyManager(token);
        s2.setVault(address(vault));

        vm.prank(owner);
        vm.expectRevert(); // not paused
        vault.setManager(address(s2));

        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.setManager(address(s2));
        assertEq(address(vault.manager()), address(s2));
    }

    // -------- Deposit --------

    function test_Deposit_PushesToManager() public {
        uint256 amount = 1_000_000; // 1.0 with 6 decimals
        vm.startPrank(user1);
        token.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user1);
        vm.stopPrank();

        assertEq(shares, amount);
        assertEq(vault.balanceOf(user1), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(vault.totalAssets(), amount);

        // funds forwarded to manager
        assertEq(token.balanceOf(address(strategy)), INITIAL_TOKENS + amount);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_Deposit_Reverts_WhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        token.approve(address(vault), 100);
        vm.expectRevert();
        vault.deposit(100, user1);
        vm.stopPrank();
    }

    function test_Deposit_Whitelist() public {
        address stranger = makeAddr("stranger");
        // whitelist active by default; stranger is not whitelisted
        vm.startPrank(stranger);
        token.mint(stranger, 1000);
        token.approve(address(vault), 1000);
        vm.expectRevert(bytes("OWL"));
        vault.deposit(1000, stranger);
        vm.stopPrank();

        // deactivate whitelist -> now OK
        vm.prank(owner);
        vault.setUserWhiteListActive(false);

        vm.startPrank(stranger);
        uint256 sh = vault.deposit(1000, stranger);
        vm.stopPrank();
        assertEq(sh, 1000);
    }

    function test_TVLCap() public {
        // set a small cap
        vm.prank(owner);
        vault.setTVLCap(1_000);

        // OK
        vm.startPrank(user1);
        token.approve(address(vault), 800);
        vault.deposit(800, user1);
        vm.stopPrank();

        // Exceed cap -> revert via ERC4626ExceededMaxDeposit
        vm.startPrank(user2);
        token.approve(address(vault), 300);
        vm.expectRevert();
        vault.deposit(300, user2);
        vm.stopPrank();
    }

    // -------- Exits (withdraw/redeem) --------

    function _depositFor(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function test_Withdraw_PullsFromManager() public {
        uint256 amount = 500_000; // 0.5
        _depositFor(user1, amount);

        // manager currently holds all (vault has 0)
        assertEq(token.balanceOf(address(vault)), 0);
        uint256 managerBalBefore = token.balanceOf(address(strategy));

        // withdraw
        vm.prank(user1);
        uint256 sharesBurned = vault.withdraw(amount, user1, user1);

        assertEq(sharesBurned, amount);
        assertEq(token.balanceOf(user1), INITIAL_TOKENS - amount + amount); // back to initial
        assertEq(token.balanceOf(address(strategy)), managerBalBefore - amount);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_Redeem_PullsFromManager() public {
        uint256 amount = 700_000;
        _depositFor(user1, amount);

        uint256 managerBalBefore = token.balanceOf(address(strategy));

        vm.prank(user1);
        uint256 assetsOut = vault.redeem(amount, user1, user1);

        assertEq(assetsOut, amount);
        assertEq(token.balanceOf(address(strategy)), managerBalBefore - amount);
        assertEq(vault.totalSupply(), 0);
    }

    function test_ZeroAmount_Exit_NoOp() public {
        _depositFor(user1, 123);

        vm.prank(user1);
        (bool success, ) = address(vault).call(abi.encodeWithSelector(vault.withdraw.selector, 0, user1, user1));
        assertTrue(success);

        vm.prank(user1);
        (success, ) = address(vault).call(abi.encodeWithSelector(vault.redeem.selector, 0, user1, user1));
        assertTrue(success);
    }

    function test_Pause_Blocks_Exits() public {
        _depositFor(user1, 10_000);

        vm.prank(owner);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1, user1, user1);

        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(1, user1, user1);
    }

    // -------- Previews & Limits --------

    function test_1to1_Previews_Derived() public {
        _depositFor(user1, 1_234_567);

        // OZ derives previews from totalAssets/totalSupply, which is 1:1 here
        assertEq(vault.convertToShares(100), 100);
        assertEq(vault.convertToAssets(100), 100);
        assertEq(vault.previewDeposit(100), 100);
        assertEq(vault.previewWithdraw(100), 100);
        assertEq(vault.previewMint(100), 100);
        assertEq(vault.previewRedeem(100), 100);
    }

    function test_MaxWithdraw_And_MaxRedeem_Use_Manager_Liquidity() public {
        // user1 deposits 1_000; manager has big liquidity
        _depositFor(user1, 1_000);

        // at this point: vault:0, manager: initial + 1_000
        // maxWithdraw(owner) = min(userBal, vault+manager)
        uint256 mw = vault.maxWithdraw(user1);
        uint256 mr = vault.maxRedeem(user1);
        assertEq(mw, 1_000);
        assertEq(mr, 1_000);
    }

    function test_MaxWithdraw_Reflects_Current_Liquidity_Scenario() public {
        // Fresh user deposits 2,000
        _depositFor(user1, 2_000);

        // Put only 500 tokens in manager; move rest to an external sink from manager
        // Since our MockERC20 can't transferFrom manager arbitrarily, we simulate by:
        // 1) Mint to an external sink, 2) Transfer out of manager to sink via vault->manager->sink route is not available.
        // Simpler approach: re-deploy strategy with limited liquidity and set it on vault.

        // Pause and switch to a new manager with only 500 balance
        MockStrategyManager limited = new MockStrategyManager(token);
        limited.setVault(address(vault));
        // Give limited manager exactly 500
        token.mint(address(limited), 500);

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.setManager(address(limited));
        vm.prank(owner);
        vault.unpause();

        // Now availableLiquidity = vaultBal (0) + managerBal (500)
        // user has 2,000 shares, but max* should be capped at 500
        assertEq(vault.maxWithdraw(user1), 500);
        assertEq(vault.maxRedeem(user1), 500);

        // and withdrawing 600 should revert via ERC4626ExceededMaxWithdraw
        vm.startPrank(user1);
        vm.expectRevert();
        vault.withdraw(600, user1, user1);
        vm.stopPrank();

        // withdrawing 500 should succeed
        vm.prank(user1);
        uint256 burned = vault.withdraw(500, user1, user1);
        assertEq(burned, 500);
    }

    // -------- Decimals/Accounting --------

    function test_Share_Decimals_Match_Asset() public view {
        assertEq(vault.decimals(), token.decimals());
    }
}
