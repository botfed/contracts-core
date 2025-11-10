// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {sBotUSD} from "../src/sBotUSD.sol";
import {ISilo, IMintableBotUSD} from "../src/RewardSilo.sol"; // only need ISilo
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* ----------------------------- Mocks ----------------------------- */

contract SBotUSDV2 is sBotUSD {
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract MockERC20Mintable is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        emit Approval(msg.sender, s, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    // NOTE: public + virtual so fee token can override
    function transferFrom(address from, address to, uint256 amt) public virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        unchecked {
            allowance[from][msg.sender] = a - amt;
        }
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        unchecked {
            balanceOf[from] -= amt;
            balanceOf[to] += amt;
        }
        emit Transfer(from, to, amt);
    }
}

// Fee-on-transfer variant to trigger InsufficientReceived
contract MockFeeOnTransfer is MockERC20Mintable {
    uint256 public feeBips; // e.g. 100 = 1%
    constructor(uint256 _feeBips) MockERC20Mintable("FOT", "FOT", 6) {
        feeBips = _feeBips;
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        unchecked {
            allowance[from][msg.sender] = a - amt;
        }
        // take fee
        uint256 fee = (amt * feeBips) / 10_000;
        uint256 net = amt - fee;
        require(balanceOf[from] >= amt, "bal");
        unchecked {
            balanceOf[from] -= amt;
            balanceOf[to] += net;
            // burn fee (or send to fee collector; burn is fine for test)
            balanceOf[address(0)] += fee;
            totalSupply -= fee;
        }
        emit Transfer(from, to, net);
        return true;
    }
}

// Silo mock that reports arbitrary maxWithdrawable and transfers what it actually holds.
contract MockSilo is ISilo {
    IERC20 private _asset;
    uint256 public reportedMax;

    constructor(IERC20 asset_) {
        _asset = asset_;
    }

    function asset() external view returns (IMintableBotUSD) {
        return IMintableBotUSD(address(_asset));
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
        // sBotUSD verifies shortfall via balance delta and reverts if got < needed
    }
}

/* ------------------------------- Tests -------------------------------- */

contract sBotUSDTest is Test {
    sBotUSD impl;
    sBotUSD vault; // proxy cast
    ERC1967Proxy proxy;
    MockERC20Mintable usdc; // 6 decimals
    MockSilo silo;

    address owner = address(0xA11CE);
    address riskAdmin = address(0xA11CE); // equals owner at initialize
    address user = address(0xB0B);
    address other = address(0xCAFE);

    function _deployVault(IERC20 asset, address _silo) internal returns (sBotUSD) {
        impl = new sBotUSD();
        bytes memory initData = abi.encodeWithSelector(
            sBotUSD.initialize.selector,
            asset,
            "Staked BotUSD",
            "sBotUSD",
            owner,
            _silo
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        return sBotUSD(address(proxy));
    }

    function setUp() public {
        usdc = new MockERC20Mintable("USDC", "USDC", 6);
        silo = new MockSilo(IERC20(address(usdc)));

        // deploy proxy vault with matching silo asset
        vault = _deployVault(IERC20(address(usdc)), address(silo));

        // fund users
        usdc.mint(user, 1_000_000e6);
        usdc.mint(other, 1_000_000e6);

        silo.setReportedMax(0);
    }

    /* ------------------------- initialize & roles ------------------------- */

    function testInit() public {
        assertEq(address(vault.asset()), address(usdc), "asset");
        assertEq(address(vault.silo()), address(silo), "silo");
        assertEq(vault.decimals(), 6);
        // only owner/riskAdmin can pause
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NotAuth()"));
        vault.pause();
    }

    function testSetRiskAdminAndPauseUnpause() public {
        vm.prank(owner);
        vault.setRiskAdmin(other);

        vm.prank(other);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(other);
        vault.unpause();
        assertFalse(vault.paused());
    }

    /* --------------------------- setSilo controls -------------------------- */

    function testSetSiloOnlyOwnerWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        MockSilo newSilo = new MockSilo(IERC20(address(usdc)));

        vm.prank(owner);
        vault.setSilo(address(newSilo));
        assertEq(address(vault.silo()), address(newSilo));

        // not paused → ExpectedPause
        vm.prank(owner);
        vault.unpause();
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vault.setSilo(address(newSilo));
    }

    function testSetSiloAssetMismatchReverts() public {
        vm.prank(owner);
        vault.pause();

        MockERC20Mintable dai = new MockERC20Mintable("DAI", "DAI", 18);
        MockSilo badSilo = new MockSilo(IERC20(address(dai)));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SiloAssetMismatch()"));
        vault.setSilo(address(badSilo));
    }

    /* ------------------------------ deposit ------------------------------- */

    function testDepositMintsOneToOne() public {
        uint256 amt = 100_000e6;
        vm.startPrank(user);
        usdc.approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, user);
        vm.stopPrank();

        assertEq(shares, amt);
        assertEq(vault.balanceOf(user), amt);
        assertEq(usdc.balanceOf(address(vault)), amt);
    }

    function testDepositRevertsOnFeeOnTransfer() public {
        // vault with fee-on-transfer asset to hit InsufficientReceived
        MockFeeOnTransfer fot = new MockFeeOnTransfer(100); // 1%
        MockSilo fotSilo = new MockSilo(IERC20(address(fot)));
        sBotUSD badVault = _deployVault(IERC20(address(fot)), address(fotSilo));

        fot.mint(user, 100_000e6);
        vm.startPrank(user);
        fot.approve(address(badVault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("InsufficientReceived(uint256,uint256)", 100_000e6, 99_000e6));
        badVault.deposit(100_000e6, user);
        vm.stopPrank();
    }

    /* -------------------- withdraw / redeem & silo pull -------------------- */

    function testWithdrawPullsFromSilo() public {
        uint256 balBefore = usdc.balanceOf(user);
        uint256 dep = 50_000e6;
        vm.startPrank(user);
        usdc.approve(address(vault), dep);
        vault.deposit(dep, user);
        vm.stopPrank();

        // fund silo and advertise liquidity
        usdc.mint(address(this), 50_000e6);
        usdc.approve(address(silo), type(uint256).max);
        silo.fund(50_000e6);
        silo.setReportedMax(50_000e6);

        // expected shares to burn should come from the vault’s own math
        uint256 expectedBurn = vault.previewWithdraw(dep);
        assertGt(expectedBurn, 0, "previewWithdraw should be > 0");

        // withdraw everything (forces pull if vault balance < dep)
        vm.startPrank(user);
        uint256 burned = vault.withdraw(dep, user, user);
        vm.stopPrank();
        uint256 balAfter = usdc.balanceOf(user);
        assertEq(burned, expectedBurn);
        assertTrue(balAfter + 1 >= balBefore && balAfter <= balBefore + 1, "post withdraw bal incorrect");
        // Remaining shares should be initial minus burned
        uint256 remaining = vault.balanceOf(user);
        assertEq(remaining + burned, dep, "shares conservation (allowing rounding in burn check above)");
    }

    function testRedeemPullsFromSilo() public {
        uint256 balBefore = usdc.balanceOf(user);
        uint256 dep = 30_000e6;
        vm.startPrank(user);
        usdc.approve(address(vault), dep);
        vault.deposit(dep, user);
        vm.stopPrank();

        usdc.mint(address(this), 30_000e6);
        usdc.approve(address(silo), type(uint256).max);
        silo.fund(30_000e6);
        silo.setReportedMax(30_000e6);

        uint256 expected = vault.previewRedeem(dep);
        vm.startPrank(user);
        uint256 received = vault.redeem(dep, user, user);
        vm.stopPrank();

        assertEq(expected, received);
        assertTrue(received + 1 >= dep * 2 && received - 1 <= dep * 2);
        assertEq(vault.balanceOf(user), 0);
        assertEq(usdc.balanceOf(user), balBefore + received - dep);
    }

    function testShortfallRevertsIfSiloCannotProvideFullAmount() public {
        uint256 dep = 40_000e6;
        vm.startPrank(user);
        usdc.approve(address(vault), dep);
        vault.deposit(dep, user);
        vm.stopPrank();

        silo.setReportedMax(40_000e6); // claim lots of liquidity but actually unfunded

        vm.startPrank(user);
        // withdraw part so a later pull is needed
        vault.withdraw(10_000e6, user, user);
        // now try to withdraw remaining 30k → silo has 0, so Shortfall
        vm.expectRevert(abi.encodeWithSignature("Shortfall(uint256,uint256)", 10_000e6, 0));
        vault.withdraw(40_000e6, user, user);
        vm.stopPrank();
    }

    /* --------------------------- view math helpers -------------------------- */

    function testMaxWithdrawAndMaxRedeemReflectLiquidity() public {
        uint256 dep = 70_000e6;
        vm.startPrank(user);
        usdc.approve(address(vault), dep);
        vault.deposit(dep, user);
        vm.stopPrank();

        // vault balance is 70k, silo reports 0
        assertEq(vault.maxWithdraw(user), dep);
        assertEq(vault.maxRedeem(user), dep);

        // add silo liquidity capacity
        silo.setReportedMax(70_000e6);
        // user balance still caps
        uint256 maxWithdraw = vault.maxWithdraw(user);
        assertTrue(maxWithdraw <= 2 * dep && maxWithdraw >= 2 * dep - 1);
        assertEq(vault.maxRedeem(user), dep);
    }

    function testTotalAssetsEqualsVaultBalPlusSiloMax() public {
        assertEq(vault.totalAssets(), 0);

        vm.startPrank(user);
        usdc.approve(address(vault), 20_000e6);
        vault.deposit(20_000e6, user);
        vm.stopPrank();

        silo.setReportedMax(30_000e6);
        assertEq(vault.totalAssets(), 50_000e6);
    }

    /* --------------------------- drainFromSilo --------------------------- */

    function testDrainFromSiloOnlyOwnerWhenPaused() public {
        usdc.mint(address(this), 25_000e6);
        usdc.approve(address(silo), type(uint256).max);
        silo.fund(25_000e6);
        silo.setReportedMax(25_000e6);

        // not paused → ExpectedPause
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        vault.drainFromSilo(10_000e6);

        vm.prank(owner);
        vault.pause();

        uint256 bal0 = usdc.balanceOf(address(vault));

        vm.prank(owner);
        vault.drainFromSilo(10_000e6);

        uint256 bal1 = usdc.balanceOf(address(vault));
        assertEq(bal1 - bal0, 10_000e6);
    }

    /* ------------------------------ UUPS upgrade ---------------------------- */

    function testUUPSUpgrade() public {
        SBotUSDV2 newImpl = new SBotUSDV2();
        vm.prank(owner);
        vault.upgradeToAndCall(address(newImpl), "");

        SBotUSDV2 v2 = SBotUSDV2(address(vault));
        assertEq(v2.version(), "v2");
    }
}
