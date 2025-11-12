// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {sBotUSD, IWhitelistable} from "../src/sBotUSD.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/* ----------------------------- Mocks ----------------------------- */

contract SBotUSDV2 is sBotUSD {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Simple ERC4626 vault for testing
contract MockVault is ERC4626, IWhitelistable {
    bool public userWhitelistActive;
    mapping(address => bool) public userWhitelist;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {
        userWhitelistActive = false;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setWhitelistActive(bool active) external {
        userWhitelistActive = active;
    }
    function setUserWhitelisted(address user, bool allowed) external {
        userWhitelist[user] = allowed;
    }
}

// Mock Silo for sBotUSD
contract MockSilo {
    IERC20 private _asset;
    uint256 public reportedMax;

    constructor(IERC20 asset_) {
        _asset = asset_;
    }

    function asset() external view returns (IERC20) {
        return _asset;
    }

    function setReportedMax(uint256 v) external {
        reportedMax = v;
    }

    function fund(uint256 amt) external {
        require(_asset.transferFrom(msg.sender, address(this), amt), "fund xfer");
    }

    function maxWithdrawable() external view returns (uint256) {
        return reportedMax;
    }

    function withdrawToVault(uint256 needed) external {
        uint256 bal = _asset.balanceOf(address(this));
        uint256 sendAmt = bal >= needed ? needed : bal;
        if (sendAmt > 0) {
            require(_asset.transfer(msg.sender, sendAmt), "send");
        }
    }
}

/* ------------------------------- Tests -------------------------------- */

contract sBotUSDTest is Test {
    sBotUSD implSBotUSD;
    sBotUSD stakingVault; // sBotUSD proxy
    ERC1967Proxy proxySBotUSD;

    MockERC20 usdc;
    MockVault baseVault; // Any ERC4626 vault
    MockSilo silo;

    address owner = address(0xA11CE);
    address user = address(0xB0B);
    address other = address(0xCAFE);

    function _deploySBotUSD(IERC20 asset, address _silo) internal returns (sBotUSD) {
        implSBotUSD = new sBotUSD();
        bytes memory initData = abi.encodeWithSelector(
            sBotUSD.initialize.selector,
            asset,
            "Staked Vault Shares",
            "sShares",
            owner,
            _silo
        );
        proxySBotUSD = new ERC1967Proxy(address(implSBotUSD), initData);
        return sBotUSD(address(proxySBotUSD));
    }

    function setUp() public {
        // 1. Deploy USDC
        usdc = new MockERC20("USDC", "USDC", 6);

        // 2. Deploy any ERC4626 vault
        baseVault = new MockVault(IERC20(address(usdc)), "Base Vault", "bVault");

        // 3. Deploy silo for sBotUSD (takes vault shares as asset)
        silo = new MockSilo(IERC20(address(baseVault)));

        // 4. Deploy sBotUSD staking vault (takes vault shares as asset)
        stakingVault = _deploySBotUSD(IERC20(address(baseVault)), address(silo));

        // 5. Fund users with USDC
        usdc.mint(user, 1_000_000e6);
        usdc.mint(other, 1_000_000e6);

        silo.setReportedMax(0);
    }

    /* ------------------------- initialize & roles ------------------------- */

    function testInit() public {
        assertEq(address(stakingVault.asset()), address(baseVault), "asset should be base vault");
        assertEq(address(stakingVault.silo()), address(silo), "silo");
        assertEq(stakingVault.decimals(), 6);
        // only owner/riskAdmin can pause
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NotAuth()"));
        stakingVault.pause();
    }

    function testSetRiskAdminAndPauseUnpause() public {
        vm.prank(owner);
        stakingVault.setRiskAdmin(other);

        vm.prank(other);
        stakingVault.pause();
        assertTrue(stakingVault.paused());

        vm.prank(other);
        stakingVault.unpause();
        assertFalse(stakingVault.paused());
    }

    /* --------------------------- setSilo controls -------------------------- */

    function testSetSiloOnlyOwnerWhenPaused() public {
        vm.prank(owner);
        stakingVault.pause();

        MockSilo newSilo = new MockSilo(IERC20(address(baseVault)));

        vm.prank(owner);
        stakingVault.setSilo(address(newSilo));
        assertEq(address(stakingVault.silo()), address(newSilo));

        // not paused → ExpectedPause
        vm.prank(owner);
        stakingVault.unpause();
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        stakingVault.setSilo(address(newSilo));
    }

    function testSetSiloAssetMismatchReverts() public {
        vm.prank(owner);
        stakingVault.pause();

        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockSilo badSilo = new MockSilo(IERC20(address(dai)));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SiloAssetMismatch()"));
        stakingVault.setSilo(address(badSilo));
    }

    /* ------------------------------ deposit ------------------------------- */

    function testDepositMintsOneToOne() public {
        // First get base vault shares
        uint256 usdcAmt = 100_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);

        // Then stake vault shares to get sBotUSD
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        uint256 shares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        assertEq(shares, vaultShares);
        assertEq(stakingVault.balanceOf(user), vaultShares);
        assertEq(IERC20(address(baseVault)).balanceOf(address(stakingVault)), vaultShares);
    }

    function testDepositMints_Whitelisted() public {
        // First get base vault shares
        uint256 usdcAmt = 100_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);

        baseVault.setWhitelistActive(true);
        baseVault.setUserWhitelisted(user, true);

        // Then stake vault shares to get sBotUSD
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        uint256 shares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        assertEq(shares, vaultShares);
        assertEq(stakingVault.balanceOf(user), vaultShares);
        assertEq(IERC20(address(baseVault)).balanceOf(address(stakingVault)), vaultShares);
    }

    function testDeposit_RevertsWhitelist() public {
        // First get base vault shares
        uint256 usdcAmt = 100_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);

        baseVault.setWhitelistActive(true);

        // Then stake vault shares to get sBotUSD
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        vm.expectRevert(sBotUSD.NotAuth.selector);
        uint256 shares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        assertEq(shares, 0);
        assertEq(stakingVault.balanceOf(user), 0);
    }

    /* -------------------- withdraw / redeem & silo pull -------------------- */
    function testWithdraw() public {
        // Setup: User gets staked shares
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        uint256 stakingShares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();
        assertEq(usdcAmt, vaultShares);

        // Withdraw
        uint256 balBefore = IERC20(address(baseVault)).balanceOf(user);
        vm.startPrank(user);
        uint256 shares = stakingVault.withdraw(vaultShares, user, user);
        vm.stopPrank();

        assertEq(shares, stakingShares);
    }

    function testWithdraw_RevertsWhitelist() public {
        // Setup: User gets staked shares
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        uint256 stakingShares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();
        assertEq(usdcAmt, vaultShares);

        baseVault.setWhitelistActive(true);

        // Withdraw
        uint256 balBefore = IERC20(address(baseVault)).balanceOf(user);
        vm.startPrank(user);
        vm.expectRevert(sBotUSD.NotAuth.selector);
        uint256 shares = stakingVault.withdraw(vaultShares, user, user);
        vm.stopPrank();

        assertEq(shares, 0);
    }

    function testRedeem() public {
        // Setup: User gets staked shares
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        uint256 stakingShares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();
        assertEq(usdcAmt, vaultShares);

        // Withdraw
        uint256 balBefore = IERC20(address(baseVault)).balanceOf(user);
        vm.startPrank(user);
        uint256 assets = stakingVault.redeem(stakingShares, user, user);
        vm.stopPrank();

        assertEq(assets, vaultShares);
    }

    function testRedeem_RevertsWhitelist() public {
        // Setup: User gets staked shares
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        uint256 stakingShares = stakingVault.deposit(vaultShares, user);
        vm.stopPrank();
        assertEq(usdcAmt, vaultShares);

        baseVault.setWhitelistActive(true);

        // Withdraw
        uint256 balBefore = IERC20(address(baseVault)).balanceOf(user);
        vm.startPrank(user);
        vm.expectRevert(sBotUSD.NotAuth.selector);
        uint256 assets = stakingVault.redeem(stakingShares, user, user);
        vm.stopPrank();

        assertEq(assets, 0);
    }

    function testWithdrawPullsFromSilo() public {
        // Setup: User gets staked shares
        uint256 usdcAmt = 50_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        // Fund silo with vault shares
        baseVault.mint(address(this), 50_000e6);
        IERC20(address(baseVault)).approve(address(silo), 50_000e6);
        silo.fund(50_000e6);
        silo.setReportedMax(50_000e6);

        // Withdraw
        uint256 balBefore = IERC20(address(baseVault)).balanceOf(user);
        vm.startPrank(user);
        uint256 assets = stakingVault.withdraw(vaultShares, user, user);
        vm.stopPrank();

        assertGt(assets, 0);
        assertGt(IERC20(address(baseVault)).balanceOf(user), balBefore);
    }

    function testRedeemPullsFromSilo() public {
        uint256 usdcAmt = 30_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        // Fund silo
        baseVault.mint(address(this), 30_000e6);
        IERC20(address(baseVault)).approve(address(silo), 30_000e6);
        silo.fund(30_000e6);
        silo.setReportedMax(30_000e6);

        uint256 expected = stakingVault.previewRedeem(vaultShares);
        vm.startPrank(user);
        uint256 received = stakingVault.redeem(vaultShares, user, user);
        vm.stopPrank();

        assertEq(expected, received);
        assertEq(stakingVault.balanceOf(user), 0);
    }

    function testShortfallRevertsIfSiloCannotProvideFullAmount() public {
        uint256 usdcAmt = 40_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        silo.setReportedMax(40_000e6); // claim liquidity but don't fund

        vm.startPrank(user);
        // withdraw part
        stakingVault.withdraw(10_000e6, user, user);
        // try to withdraw more than available → Shortfall
        vm.expectRevert(abi.encodeWithSignature("Shortfall(uint256,uint256)", 10_000e6, 0));
        stakingVault.withdraw(40_000e6, user, user);
        vm.stopPrank();
    }

    /* --------------------------- view math helpers -------------------------- */

    function testMaxWithdrawAndMaxRedeemReflectLiquidity() public {
        uint256 usdcAmt = 70_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        // vault balance is 70k, silo reports 0
        assertEq(stakingVault.maxWithdraw(user), vaultShares);
        assertEq(stakingVault.maxRedeem(user), vaultShares);

        // add silo liquidity capacity
        silo.setReportedMax(70_000e6);
        uint256 maxWithdraw = stakingVault.maxWithdraw(user);
        assertTrue(maxWithdraw <= 2 * vaultShares && maxWithdraw >= 2 * vaultShares - 1);
    }

    function testTotalAssetsEqualsVaultBalPlusSiloMax() public {
        assertEq(stakingVault.totalAssets(), 0);

        uint256 usdcAmt = 20_000e6;
        vm.startPrank(user);
        usdc.approve(address(baseVault), usdcAmt);
        uint256 vaultShares = baseVault.deposit(usdcAmt, user);
        IERC20(address(baseVault)).approve(address(stakingVault), vaultShares);
        stakingVault.deposit(vaultShares, user);
        vm.stopPrank();

        silo.setReportedMax(30_000e6);
        assertEq(stakingVault.totalAssets(), 50_000e6);
    }

    /* --------------------------- drainFromSilo --------------------------- */

    function testDrainFromSiloOnlyOwnerWhenPaused() public {
        // Fund silo with vault shares
        baseVault.mint(address(this), 25_000e6);
        IERC20(address(baseVault)).approve(address(silo), 25_000e6);
        silo.fund(25_000e6);
        silo.setReportedMax(25_000e6);

        // not paused → ExpectedPause
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        stakingVault.drainFromSilo(10_000e6);

        vm.prank(owner);
        stakingVault.pause();

        uint256 bal0 = IERC20(address(baseVault)).balanceOf(address(stakingVault));

        vm.prank(owner);
        stakingVault.drainFromSilo(10_000e6);

        uint256 bal1 = IERC20(address(baseVault)).balanceOf(address(stakingVault));
        assertEq(bal1 - bal0, 10_000e6);
    }

    /* --------------------------- zapBuy/zapSell -------------------------- */

    function testZapBuy() public {
        uint256 usdcAmount = 25_000e6;

        vm.startPrank(user);
        usdc.approve(address(stakingVault), usdcAmount);
        uint256 shares = stakingVault.zapBuy(usdcAmount, user);
        vm.stopPrank();

        assertEq(stakingVault.balanceOf(user), shares);
        assertGt(shares, 0);
        assertEq(usdc.balanceOf(user), 1_000_000e6 - usdcAmount);
    }

    function testZapSell() public {
        uint256 usdcAmount = 25_000e6;

        // First zapBuy
        vm.startPrank(user);
        usdc.approve(address(stakingVault), usdcAmount);
        uint256 shares = stakingVault.zapBuy(usdcAmount, user);
        vm.stopPrank();
        console.log("shares", shares, stakingVault.previewDeposit(usdcAmount));

        // zapSell
        vm.startPrank(user);
        stakingVault.approve(address(stakingVault), shares);
        uint256 usdcReceived = stakingVault.zapSell(shares, user, user);
        vm.stopPrank();

        assertGt(usdcReceived, 0);
        assertEq(stakingVault.balanceOf(user), 0);
        // Should get back approximately what was put in
        assertApproxEqAbs(usdc.balanceOf(user), 1_000_000e6, 1e6);
    }

    function testZapBuy_FailWhitelist_NoneWhitelisted() public {
        uint256 usdcAmount = 25_000e6;

        baseVault.setWhitelistActive(true);

        vm.startPrank(user);
        usdc.approve(address(stakingVault), usdcAmount);
        vm.expectRevert();
        uint256 shares = stakingVault.zapBuy(usdcAmount, user);
        vm.stopPrank();

        assertEq(stakingVault.balanceOf(user), 0);
    }

    function testZapBuy_FailWhitelist_OneWhitelisted() public {
        uint256 usdcAmount = 25_000e6;

        baseVault.setWhitelistActive(true);
        baseVault.setUserWhitelisted(makeAddr("0xrando"), true);

        vm.startPrank(user);
        usdc.approve(address(stakingVault), usdcAmount);
        vm.expectRevert();
        uint256 shares = stakingVault.zapBuy(usdcAmount, user);
        vm.stopPrank();

        assertEq(stakingVault.balanceOf(user), 0);
    }

    function testZapBuy_WithWhitelist() public {
        uint256 usdcAmount = 25_000e6;

        baseVault.setWhitelistActive(true);
        baseVault.setUserWhitelisted(user, true);

        vm.startPrank(user);
        usdc.approve(address(stakingVault), usdcAmount);
        uint256 shares = stakingVault.zapBuy(usdcAmount, user);
        vm.stopPrank();

        assertEq(stakingVault.balanceOf(user), shares);
    }

    /* ------------------------------ UUPS upgrade ---------------------------- */

    function testUUPSUpgrade() public {
        SBotUSDV2 newImpl = new SBotUSDV2();
        vm.prank(owner);
        stakingVault.upgradeToAndCall(address(newImpl), "");

        SBotUSDV2 v2 = SBotUSDV2(address(stakingVault));
        assertEq(v2.version(), "v2");
    }
}
