// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {RewardSilo, IMintableBotUSD, OwnableUpgradeable} from "../src/RewardSilo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";


/* ---------------------- Mock BotUSD (mintRewards gated) ---------------------- */
contract MockMintableBotUSD is IERC20 {
    string public name = "Mock BotUSD";
    string public symbol = "mBotUSD";
    uint8 public decimals = 6;

    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) internal _allow;
    uint256 internal _supply;

    address public rewarder;

    event RewarderSet(address indexed oldRewarder, address indexed newRewarder);

    function setRewarder(address r) external {
        emit RewarderSet(rewarder, r);
        rewarder = r;
    }

    // IERC20
    function totalSupply() external view returns (uint256) {
        return _supply;
    }
    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }
    function allowance(address o, address s) external view returns (uint256) {
        return _allow[o][s];
    }

    function approve(address s, uint256 amt) external returns (bool) {
        _allow[msg.sender][s] = amt;
        emit Approval(msg.sender, s, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= amt, "allow");
        unchecked {
            _allow[from][msg.sender] = a - amt;
        }
        _transfer(from, to, amt);
        return true;
    }

    function _transfer(address from, address to, uint256 amt) internal {
        require(_bal[from] >= amt, "bal");
        unchecked {
            _bal[from] -= amt;
            _bal[to] += amt;
        }
        emit Transfer(from, to, amt);
    }

    // RewardSilo expects: only rewarder can mint to itself
    function mintRewards(uint256 amount) external {
        require(msg.sender == rewarder, "not-rewarder");
        _supply += amount;
        _bal[msg.sender] += amount;
        emit Transfer(address(0), msg.sender, amount);
    }
}

/* --------------------------------- Tests ---------------------------------- */
contract RewardSiloTest is Test {
    uint256 constant WEEK = 7 days;

    RewardSilo impl; // implementation
    RewardSilo silo; // proxy (cast to RewardSilo)
    ERC1967Proxy proxy; // raw proxy
    MockMintableBotUSD token;

    address owner = address(0xA11CE);
    address vault = address(0xBEEF);
    address feeReceiver = address(0xFEEE);
    address stranger = address(0xCAFE);

    /* --------- Setup: deploy impl + proxy, call initialize via proxy --------- */
    function setUp() public {
        token = new MockMintableBotUSD();
        impl = new RewardSilo();

        bytes memory initData = abi.encodeWithSelector(
            RewardSilo.initialize.selector,
            IMintableBotUSD(address(token)),
            owner,
            vault,
            feeReceiver,
            0
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        silo = RewardSilo(address(proxy));
        vm.prank(owner);
        silo.setDripDuration(WEEK);
        assertEq(silo.dripDuration(), WEEK);

        // allow proxy (silo) to call token.mintRewards
        token.setRewarder(address(silo));
    }

    /* ------------------------------- Helpers -------------------------------- */
    function _approxEq(uint256 a, uint256 b, uint256 tol) internal pure {
        if (a > b) require(a - b <= tol, "approx(a>b)");
        else require(b - a <= tol, "approx(b>a)");
    }

    /* ---------------------------- Basic smoke tests -------------------------- */
    function testInitThroughProxy() public {
        assertEq(address(silo.asset()), address(token), "asset");
        assertEq(silo.vault(), vault, "vault");
        // Ownable: ensure non-owner cannot pause
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        silo.pause();
    }

    /* ---------------------------- Pause / Unpause ---------------------------- */
    function testOnlyOwnerPauseUnpause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        silo.pause();

        vm.prank(owner);
        silo.pause();
        assertTrue(silo.paused());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        silo.unpause();

        vm.prank(owner);
        silo.unpause();
        assertFalse(silo.paused());
    }

    /* ----------------------- setVault (onlyOwner, paused) -------------------- */
    function testSetVaultOnlyOwnerWhenPaused() public {
        vm.prank(owner);
        silo.pause();

        address newVault = address(0xD00D);

        vm.expectEmit(true, true, false, true, address(silo));
        emit RewardSilo.VaultSet(vault, newVault);

        vm.prank(owner);
        silo.setVault(newVault);
        assertEq(silo.vault(), newVault, "vault updated");

        // Not paused -> revert
        vm.prank(owner);
        silo.unpause();
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        silo.setVault(address(0x1234));
    }

    /* -------------------------- Drip: single schedule ------------------------ */
    function testMintRewardsThroughProxyLinearDrip() public {
        uint256 amt = 1_000_000e6;

        // t=0
        vm.prank(owner);
        uint256 t0 = block.timestamp;
        vm.expectEmit(false, false, false, true, address(silo));
        emit RewardSilo.Minted(amt, t0);
        silo.mintRewards(amt);

        assertEq(silo.maxWithdrawable(), 0, "t=0 available");

        vm.warp(block.timestamp + WEEK / 2);
        uint256 half = silo.maxWithdrawable();
        assertApproxEqAbs(half, amt / 2, 1, "half");

        vm.warp(block.timestamp + WEEK / 2 + 1);
        uint256 full = silo.maxWithdrawable();
        assertApproxEqAbs(full, amt, 1, "full");
    }
    function testMintRewards_ProjectedAPR() public {
        uint256 amt = 1_000_000e6;

        // t=0
        vm.prank(owner);
        silo.mintRewards(amt);

        assertEq(silo.totalMinted(), amt);
        assertEq(silo.lastUndripped(), amt);
        assertEq(silo.lastDripDuration(), silo.dripDuration());
        assertEq(silo.lastSupply(), silo.asset().totalSupply());
        assertEq(silo.projectedApr(), 10_000 * amt * 365 days / (silo.dripDuration() * silo.asset().totalSupply()));
        console.log("Projected APR", silo.projectedApr());
    }

    /* ------------------------- Withdraw: only vault -------------------------- */
    function testWithdrawOnlyVaultAndStateUpdate() public {
        uint256 amt = 500_000e6;

        vm.prank(owner);
        silo.mintRewards(amt);

        vm.warp(block.timestamp + WEEK / 2);
        uint256 available = silo.maxWithdrawable();
        console.log(amt, available, silo.asset().balanceOf(address(silo)));
        _approxEq(available, amt / 2, 1);

        // non-vault cannot withdraw
        vm.prank(stranger);
        vm.expectRevert(RewardSilo.NotAuth.selector);
        silo.withdrawToVault(available);

        // vault withdraws a portion
        uint256 pull = available / 2;
        vm.prank(vault);
        vm.expectEmit(false, false, false, true, address(silo));
        emit RewardSilo.Withdrawn(pull);
        silo.withdrawToVault(pull);

        // availability reduced by pull
        uint256 left = silo.maxWithdrawable();
        _approxEq(left, available - pull, 2);
    }

    /* ---------------------- Rollover carries undripped ----------------------- */
    function testRolloverCarriesUndripped() public {
        uint256 A = 900_000e6;
        uint256 B = 300_000e6;

        // Mint A, let 1/3 drip
        vm.prank(owner);
        silo.mintRewards(A);
        vm.warp(block.timestamp + WEEK / 3);

        uint256 beforeRollAvail = silo.maxWithdrawable();
        _approxEq(beforeRollAvail, A / 3, 2);

        // Mint B (rollover): accumulated becomes A/3, lastUndripped = 2A/3 + B
        vm.prank(owner);
        silo.mintRewards(B);

        // immediately after: elapsed=0 => available == accumulated == A/3
        uint256 afterAccum = silo.maxWithdrawable();
        _approxEq(afterAccum, A / 3, 2);

        // half week after rollover
        vm.warp(block.timestamp + WEEK / 2);
        uint256 remainingPlusB = ((2 * A) / 3) + B;
        uint256 expectedNewly = remainingPlusB / 2;
        uint256 expectedAvail = (A / 3) + expectedNewly;

        uint256 got = silo.maxWithdrawable();
        _approxEq(got, expectedAvail, 3);
    }

    /* -------------------------- Pause behavior semantics --------------------- */
    function testPausedBehavior() public {
        uint256 amt = 100_000e6;

        vm.prank(owner);
        silo.mintRewards(amt);

        vm.prank(owner);
        silo.pause();

        // paused => available=0
        assertEq(silo.maxWithdrawable(), 0);

        // paused => mintRewards reverts
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        silo.mintRewards(1);

        // paused => withdrawToVault reverts
        vm.prank(vault);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        silo.withdrawToVault(1);

        // time passes while paused; on unpause, availability jumps forward
        vm.warp(block.timestamp + WEEK);
        vm.prank(owner);
        silo.unpause();

        assertApproxEqAbs(silo.maxWithdrawable(), amt, 1);
    }

    /* -------------------- Availability capped to on-chain bal ---------------- */
    function testAvailabilityCappedToBalance() public {
        uint256 amt = 200_000e6;

        vm.prank(owner);
        silo.mintRewards(amt);

        // Let 3/4 drip
        vm.warp(block.timestamp + (3 * WEEK) / 4);
        uint256 theoretical = silo.maxWithdrawable();
        _approxEq(theoretical, (amt * 3) / 4, 2);

        // Simulate unexpected token outflow: move 50k from silo's balance
        vm.prank(address(silo)); // spoof caller as the proxy (holder)
        IERC20(address(token)).transfer(address(0xDEAD), 50_000e6);

        // Now availability = min(theoretical, balanceOf(silo))
        uint256 bal = IERC20(address(token)).balanceOf(address(silo));
        uint256 capped = silo.maxWithdrawable();
        assertEq(capped, bal, "capped to balance");
    }

    /* ------------------------------- Events ---------------------------------- */
    function testEventsOnMintAndWithdraw() public {
        uint256 amt = 123_456e6;

        vm.prank(owner);
        uint256 t0 = block.timestamp;
        vm.expectEmit(false, false, false, true, address(silo));
        emit RewardSilo.Minted(amt, t0);
        silo.mintRewards(amt);

        vm.warp(block.timestamp + WEEK);
        vm.prank(vault);
        vm.expectEmit(false, false, false, true, address(silo));
        emit RewardSilo.Withdrawn(amt);
        silo.withdrawToVault(amt);
    }

    function testUUPSUpgrade() public {
        RewardSilo newImpl = new RewardSilo();

        vm.prank(owner); // onlyOwner
        silo.upgradeToAndCall(address(newImpl), abi.encodeWithSelector(newImpl.initializeV1_1.selector));
        assertEq(silo.version(), 1);
    }
}
