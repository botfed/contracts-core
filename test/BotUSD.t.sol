// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BotUSD} from "../src/BotUSD.sol";

/* ────────────────────────────────────────────
 *                    Mocks
 * ──────────────────────────────────────────── */

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

    function transferFrom(address from, address to, uint256 amount) external virtual override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ALLOW");
        require(balanceOf[from] >= amount, "BAL");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// Deflationary token (fee-on-transfer via transferFrom)
contract DeflToken is MockERC20 {
    uint256 public feeBps = 100; // 1% fee
    constructor() MockERC20("Defl", "DEF", 6) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ALLOW");
        require(balanceOf[from] >= amount, "BAL");
        allowance[from][msg.sender] -= amount;
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 out = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += out;
        emit Transfer(from, to, out);
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

    // Marked virtual so we can override in shortfall manager
    function withdrawToVault(uint256 amount) public virtual {
        require(msg.sender == vault, "only vault");
        asset.transfer(vault, amount);
    }

    function maxWithdrawable() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

// Returns less than requested to trigger Shortfall
contract ShortManager is MockStrategyManager {
    constructor(IERC20 a) MockStrategyManager(a) {}

    function withdrawToVault(uint256 amount) public override {
        require(msg.sender == vault, "only vault");
        uint256 half = amount / 2;
        IERC20(address(asset)).transfer(vault, half);
    }
}

/* ────────────────────────────────────────────
 *                Test Suite
 * ──────────────────────────────────────────── */

contract BotUSDTest is Test {
    BotUSD public vault;
    BotUSD public vaultImpl;
    MockERC20 public asset; // 6 decimals (USDC-like)
    MockStrategyManager public manager;

    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public rando = makeAddr("rando");

    uint256 constant INITIAL_TOKENS = 1_000_000_000; // 1e9 (with 6 decimals)

    /* Re-declare events (matching vault) so expectEmit can use them */
    event ManagerSet(address indexed a);
    event RiskAdminSet(address indexed a);
    event CapitalDeployed(address strat, uint256 amount);
    event LiquidityPulled(uint256 request, uint256 got);
    event UserWhitelist(address indexed user, bool isWhitelisted);
    event UserWhitelistActive(bool isActive);
    event TVLCapChanged(uint256 newCap);

    function setUp() public {
        asset = new MockERC20("Mock USDC", "mUSDC", 6);
        manager = new MockStrategyManager(asset);

        vaultImpl = new BotUSD();
        bytes memory initData = abi.encodeWithSelector(
            BotUSD.initialize.selector,
            address(asset),
            "BotFed USDC Vault",
            "botUSDC",
            owner,
            address(manager)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(vaultImpl), initData);
        vault = BotUSD(payable(address(proxy)));

        manager.setVault(address(vault));

        // Whitelist
        vm.prank(owner);
        vault.setUserWhitelist(user1, true);
        vm.prank(owner);
        vault.setUserWhitelist(user2, true);

        // Seed balances
        asset.mint(user1, INITIAL_TOKENS);
        asset.mint(user2, INITIAL_TOKENS);
        asset.mint(address(manager), INITIAL_TOKENS);
    }

    /* ── Initialization & Admin ─────────────────────────────────────────────── */

    function test_Init() public view {
        assertEq(address(vault.asset()), address(asset));
        assertEq(vault.name(), "BotFed USDC Vault");
        assertEq(vault.symbol(), "botUSDC");
        assertEq(vault.owner(), owner);
        assertEq(address(vault.manager()), address(manager));
        assertFalse(vault.paused());
        assertEq(vault.decimals(), 6);
        // defaults
        assertTrue(vault.userWhitelistActive());
        assertEq(vault.tvlCap(), type(uint256).max);
    }

    function test_Pause_Unpause_Access() public {
        vm.prank(user1);
        vm.expectRevert(); // onlyOwner
        vault.pause();

        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(user1);
        vm.expectRevert(); // onlyOwner
        vault.unpause();

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_SetManager_OnlyOwner_WhenPaused() public {
        MockStrategyManager s2 = new MockStrategyManager(asset);
        s2.setVault(address(vault));

        vm.prank(owner);
        vm.expectRevert(); // not paused
        vault.setManager(address(s2));

        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ManagerSet(address(s2));
        vault.setManager(address(s2));
        assertEq(address(vault.manager()), address(s2));
    }

    function test_SetManager_Revert_Zero_And_AssetMismatch() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert(BotUSD.ZeroAddress.selector);
        vault.setManager(address(0));

        MockERC20 otherAsset = new MockERC20("X", "X", 6);
        MockStrategyManager bad = new MockStrategyManager(otherAsset);
        bad.setVault(address(vault));

        vm.prank(owner);
        vm.expectRevert(bytes("A"));
        vault.setManager(address(bad));
    }

    function test_RiskAdmin_Can_Set_Params_After_Rotation() public {
        address newRisk = makeAddr("newRisk");

        // rando cannot
        vm.prank(rando);
        vm.expectRevert(); // "ORA" from modifier
        vault.setUserWhitelistActive(false);

        // rotate risk admin (owner-only)
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RiskAdminSet(newRisk);
        vault.setRiskAdmin(newRisk);
        assertEq(vault.riskAdmin(), newRisk);

        // risk admin can set params
        vm.prank(newRisk);
        vm.expectEmit(false, false, false, true);
        emit UserWhitelistActive(false);
        vault.setUserWhitelistActive(false);
        assertEq(vault.userWhitelistActive(), false);

        vm.prank(newRisk);
        vm.expectEmit(false, false, false, true);
        emit TVLCapChanged(1234);
        vault.setTVLCap(1234);
        assertEq(vault.tvlCap(), 1234);

        vm.prank(newRisk);
        vm.expectEmit(true, false, false, true);
        emit UserWhitelist(user1, true);
        vault.setUserWhitelist(user1, true);
        assertTrue(vault.userIsWhitelisted(user1));
    }

    /* ── Deposit ───────────────────────────────────────────────────────────── */

    function _approveAndDeposit(address user, uint256 amount) internal returns (uint256) {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();
        return shares;
    }

    function test_Deposit_PushesToManager() public {
        uint256 amount = 1_000_000; // 1.0
        uint256 shares = _approveAndDeposit(user1, amount);

        assertEq(shares, amount);
        assertEq(vault.balanceOf(user1), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(vault.totalAssets(), amount);

        // funds forwarded to manager
        assertEq(asset.balanceOf(address(manager)), INITIAL_TOKENS + amount);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function test_Deposit_Reverts_WhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(user1);
        asset.approve(address(vault), 100);
        vm.expectRevert();
        vault.deposit(100, user1);
        vm.stopPrank();
    }

    function test_Deposit_Whitelist() public {
        address stranger = makeAddr("stranger");
        asset.mint(stranger, 1000);
        vm.startPrank(stranger);
        asset.approve(address(vault), 1000);
        vm.expectRevert(bytes("OWL"));
        vault.deposit(1000, stranger);
        vm.stopPrank();

        vm.prank(owner);
        vault.setUserWhitelistActive(false);

        vm.startPrank(stranger);
        uint256 sh = vault.deposit(1000, stranger);
        vm.stopPrank();
        assertEq(sh, 1000);
    }

    function test_TVLCap() public {
        vm.prank(owner);
        vault.setTVLCap(1_000);

        _approveAndDeposit(user1, 800);

        vm.startPrank(user2);
        asset.approve(address(vault), 300);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit
        vault.deposit(300, user2);
        vm.stopPrank();

        // boundary: if cap == totalSupply, maxDeposit == 0
        vm.startPrank(owner);
        vault.setTVLCap(vault.totalSupply());
        assertEq(vault.maxDeposit(user1), 0);
        vm.stopPrank();
    }

    function test_Deposit_Allows_Donations() public {
        // donate before deposit (should not break "received >= assets" check)
        asset.mint(address(vault), 500);

        vm.startPrank(user1);
        asset.approve(address(vault), 1000);
        uint256 sh = vault.deposit(1000, user1);
        vm.stopPrank();

        assertEq(sh, 1000);
        assertEq(asset.balanceOf(address(vault)), 500); // pushed to manager
    }

    function test_Deposit_Reverts_On_FeeOnTransfer() public {
        DeflToken d = new DeflToken();
        MockStrategyManager m2 = new MockStrategyManager(d);
        BotUSD impl = new BotUSD();

        bytes memory init = abi.encodeWithSelector(
            BotUSD.initialize.selector,
            address(d),
            "n",
            "s",
            owner,
            address(m2)
        );
        BotUSD v = BotUSD(address(new ERC1967Proxy(address(impl), init)));
        m2.setVault(address(v));

        address u = makeAddr("u");
        d.mint(u, 10_000);

        vm.prank(owner);
        v.setUserWhitelist(u, true);

        vm.startPrank(u);
        d.approve(address(v), 10_000);
        vm.expectRevert(bytes("RAM"));
        v.deposit(10_000, u);
        vm.stopPrank();
    }

    /* ── Withdraw / Redeem ─────────────────────────────────────────────────── */

    function test_Withdraw_PullsFromManager() public {
        uint256 amount = 500_000;
        _approveAndDeposit(user1, amount);

        assertEq(asset.balanceOf(address(vault)), 0);
        uint256 managerBalBefore = asset.balanceOf(address(manager));

        vm.prank(user1);
        uint256 sharesBurned = vault.withdraw(amount, user1, user1);

        assertEq(sharesBurned, amount);
        assertEq(asset.balanceOf(user1), INITIAL_TOKENS);
        assertEq(asset.balanceOf(address(manager)), managerBalBefore - amount);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_Redeem_PullsFromManager() public {
        uint256 amount = 700_000;
        _approveAndDeposit(user1, amount);

        uint256 managerBalBefore = asset.balanceOf(address(manager));

        vm.prank(user1);
        uint256 assetsOut = vault.redeem(amount, user1, user1);

        assertEq(assetsOut, amount);
        assertEq(asset.balanceOf(address(manager)), managerBalBefore - amount);
        assertEq(vault.totalSupply(), 0);
    }

    function test_ZeroAmount_Exit_NoOp() public {
        _approveAndDeposit(user1, 123);

        vm.prank(user1);
        (bool success, ) = address(vault).call(abi.encodeWithSelector(vault.withdraw.selector, 0, user1, user1));
        assertTrue(success);

        vm.prank(user1);
        (success, ) = address(vault).call(abi.encodeWithSelector(vault.redeem.selector, 0, user1, user1));
        assertTrue(success);
    }

    function test_Pause_Blocks_Exits() public {
        _approveAndDeposit(user1, 10_000);

        vm.prank(owner);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(1, user1, user1);

        vm.prank(user1);
        vm.expectRevert();
        vault.redeem(1, user1, user1);
    }

    function test_Whitelist_Enforced_On_Exit() public {
        _approveAndDeposit(user1, 1000);

        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(bytes("OWL"));
        vault.withdraw(1, stranger, stranger);
        vm.expectRevert(bytes("OWL"));
        vault.redeem(1, stranger, stranger);
        vm.stopPrank();

        vm.prank(owner);
        vault.setUserWhitelistActive(false);

        // now can interact
        asset.mint(stranger, 1);
        vm.startPrank(stranger);
        IERC20(address(asset)).approve(address(vault), 1);
        vault.deposit(1, stranger);
        vault.withdraw(1, stranger, stranger);
        vm.stopPrank();
    }

    function test_Events_Deposit_And_Withdraw() public {
        // Deposit → CapitalDeployed
        vm.startPrank(user1);
        asset.approve(address(vault), 100);
        vm.expectEmit(true, false, false, true);
        emit CapitalDeployed(address(manager), 100);
        vault.deposit(100, user1);
        vm.stopPrank();

        // Withdraw → LiquidityPulled (vault will need to pull since it holds 0)
        vm.prank(user1);
        vm.expectEmit(false, false, false, true);
        emit LiquidityPulled(100, 100);
        vault.withdraw(100, user1, user1);
    }

    /* ── Previews & Limits ─────────────────────────────────────────────────── */

    function test_1to1_Previews_Derived() public {
        _approveAndDeposit(user1, 1_234_567);

        assertEq(vault.convertToShares(100), 100);
        assertEq(vault.convertToAssets(100), 100);
        assertEq(vault.previewDeposit(100), 100);
        assertEq(vault.previewWithdraw(100), 100);
        assertEq(vault.previewMint(100), 100);
        assertEq(vault.previewRedeem(100), 100);
    }

    function test_MaxWithdraw_And_MaxRedeem_Use_Manager_Liquidity() public {
        _approveAndDeposit(user1, 1_000);

        uint256 mw = vault.maxWithdraw(user1);
        uint256 mr = vault.maxRedeem(user1);
        assertEq(mw, 1_000);
        assertEq(mr, 1_000);
    }

    function test_MaxWithdraw_Reflects_Current_Liquidity_Scenario() public {
        _approveAndDeposit(user1, 2_000);

        // switch to manager with limited liquidity (500)
        MockStrategyManager limited = new MockStrategyManager(asset);
        limited.setVault(address(vault));
        asset.mint(address(limited), 500);

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.setManager(address(limited));
        vm.prank(owner);
        vault.unpause();

        assertEq(vault.maxWithdraw(user1), 500);
        assertEq(vault.maxRedeem(user1), 500);

        vm.startPrank(user1);
        vm.expectRevert(); // ERC4626ExceededMaxWithdraw
        vault.withdraw(600, user1, user1);
        vm.stopPrank();

        vm.prank(user1);
        uint256 burned = vault.withdraw(500, user1, user1);
        assertEq(burned, 500);
    }

    function test_PullFromManager_Shortfall_Reverts() public {
        _approveAndDeposit(user1, 1_000);

        ShortManager shorty = new ShortManager(asset);
        shorty.setVault(address(vault));

        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.setManager(address(shorty));
        vm.prank(owner);
        vault.unpause();

        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(600, user1, user1);
    }

    /* ── Decimals & Upgradeability ─────────────────────────────────────────── */

    function test_Share_Decimals_Match_Asset() public view {
        assertEq(vault.decimals(), asset.decimals());
    }

    function test_Upgrade_UUPS_OnlyOwner() public {
        BotUSD newImpl = new BotUSD();

        vm.prank(rando);
        vm.expectRevert(); // onlyOwner
        vault.upgradeToAndCall(address(newImpl), "");

        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        // state intact
        assertEq(address(vault.asset()), address(asset));
        assertEq(address(vault.manager()), address(manager));
    }

    /* ── Fuzz ──────────────────────────────────────────────────────────────── */

    function testFuzz_DepositRedeem_Roundtrip(uint128 amtRaw) public {
        uint256 amt = uint256(amtRaw % 10_000_000); // keep gas sane
        vm.assume(amt > 0);

        asset.mint(user1, amt);

        vm.prank(owner);
        vault.setUserWhitelist(user1, true);

        vm.startPrank(user1);
        asset.approve(address(vault), amt);
        uint256 sh = vault.deposit(amt, user1);
        uint256 out = vault.redeem(sh, user1, user1);
        vm.stopPrank();

        assertEq(out, amt);
        assertEq(vault.totalSupply(), 0);
    }
}
