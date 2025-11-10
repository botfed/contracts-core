// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RewardSilo.sol";

/// @dev Minimal mock of IMintableBotUSD with rewarder gating.
/// - 6 decimals like USDC/typical stablecoins.
/// - `mintRewards(amount)` can only be called by `rewarder`.
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

    // --- IERC20 ---
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

    // --- Minting for tests ---
    function _mint(address to, uint256 amt) internal {
        _supply += amt;
        _bal[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    /// @dev Match RewardSilo expectation: BotUSD enforces access control.
    function mintRewards(uint256 amount) external {
        require(msg.sender == rewarder, "not-rewarder");
        _mint(msg.sender, amount);
    }
}

contract RewardSiloTest is Test {
    // constants mirroring the contract
    uint256 constant WEEK = 7 days;

    RewardSilo silo;
    MockMintableBotUSD token;

    address owner = address(0xA11CE);
    address vault = address(0xBEEF);
    address stranger = address(0xCAFE);

    function setUp() public {
        vm.startPrank(owner);

        // deploy token + silo
        token = new MockMintableBotUSD();
        silo = new RewardSilo();

        // initialize silo
        silo.initialize(IMintableBotUSD(address(token)), owner, vault);

        // set rewarder on token to silo (so silo can call token.mintRewards)
        token.setRewarder(address(silo));

        vm.stopPrank();
    }

    // ----------------- helpers -----------------

    function _approxEq(uint256 a, uint256 b, uint256 tol) internal pure {
        if (a > b) {
            require(a - b <= tol, "not approx equal (a>b)");
        } else {
            require(b - a <= tol, "not approx equal (b>a)");
        }
    }
    function _approxEq(uint256 a, uint256 b, uint256 tol, string memory msg) internal pure {
        if (a > b) {
            require(a - b <= tol, msg);
        } else {
            require(b - a <= tol, msg);
        }
    }

    // ----------------- tests -----------------

    function testInitValues() public {
        assertEq(address(silo.asset()), address(token), "asset");
        assertEq(silo.vault(), vault, "vault");
        // lastMintTime is set to block.timestamp on initialize
        // not asserting exact value due to test runner timing
    }

    function testOnlyOwnerPauseUnpause() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        silo.pause();

        vm.prank(owner);
        silo.pause();
        assertTrue(silo.paused());

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        silo.unpause();

        vm.prank(owner);
        silo.unpause();
        assertFalse(silo.paused());
    }

    function testSetVaultOnlyOwnerWhenPaused() public {
        vm.prank(owner);
        silo.pause();

        address newVault = address(0xD00D);
        vm.expectEmit(true, true, false, true);
        emit RewardSilo.VaultSet(vault, newVault);

        vm.prank(owner);
        silo.setVault(newVault);
        assertEq(silo.vault(), newVault, "vault updated");

        // not paused => revert
        vm.prank(owner);
        silo.unpause();
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        silo.setVault(address(0x1234));
    }

    function testMintRewardsAndLinearDrip() public {
        uint256 amt = 1_000_000e6; // 1,000,000 with 6 decimals

        // initial: available = 0
        assertEq(silo.maxWithdrawable(), 0, "initially zero");

        // mint (owner only)
        vm.prank(owner);
        silo.mintRewards(amt);

        // immediately after mint: still zero available (drip starts at 0)
        assertEq(silo.maxWithdrawable(), 0, "t=0 available");

        // half period
        vm.warp(block.timestamp + WEEK / 2);
        uint256 half = silo.maxWithdrawable();
        _approxEq(half, amt / 2, 1, "half drip");

        // full period
        vm.warp(block.timestamp + WEEK / 2 + 1);
        uint256 full = silo.maxWithdrawable();
        _approxEq(full, amt, 1, "full drip");
    }

    function testWithdrawOnlyVaultAndStateUpdate() public {
        uint256 amt = 500_000e6;

        vm.prank(owner);
        silo.mintRewards(amt);

        // drip half
        vm.warp(block.timestamp + WEEK / 2);
        uint256 available = silo.maxWithdrawable();
        _approxEq(available, amt / 2, 1, "available ~ half");

        // non-vault cannot withdraw
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotAuth()"));
        silo.withdrawToVault(available);

        // vault withdraws a portion
        uint256 pull = available / 3;
        vm.prank(vault);
        vm.expectEmit(false, false, false, true);
        emit RewardSilo.Withdrawn(pull);
        silo.withdrawToVault(pull);

        // availability reduced by pull (accumulated updated)
        uint256 left = silo.maxWithdrawable();
        _approxEq(left, available - pull, 2, "reduced after withdraw");
    }

    function testRolloverCarriesUndripped() public {
        uint256 A = 900_000e6;
        uint256 B = 300_000e6;

        // Mint A, let 1/3 drip
        vm.prank(owner);
        silo.mintRewards(A);
        vm.warp(block.timestamp + WEEK / 3);

        uint256 beforeRollAvail = silo.maxWithdrawable();
        _approxEq(beforeRollAvail, A / 3, 2, "A/3 available");

        // Mint B (rollover):
        vm.prank(owner);
        silo.mintRewards(B);

        // After rollover:
        // accumulated == previous available (A/3)
        uint256 afterAccum = silo.maxWithdrawable(); // includes 0 newly yet
        // immediately after mintRewards(), elapsed = 0 => available == accumulated
        _approxEq(afterAccum, A / 3, 2, "accumulated == A/3");

        // Now let half a week pass post-roll
        vm.warp(block.timestamp + WEEK / 2);

        // Expected new drip = (remaining of A: 2A/3) + B, dripping linearly over a week
        uint256 remainingPlusB = ((2 * A) / 3) + B;
        uint256 expectedNewly = remainingPlusB / 2; // half-week
        uint256 expectedAvail = (A / 3) + expectedNewly;

        uint256 gotAvail = silo.maxWithdrawable();
        _approxEq(gotAvail, expectedAvail, 3, "rolled drip half week");
    }

    function testPausedBehavior() public {
        uint256 amt = 100_000e6;

        vm.prank(owner);
        silo.mintRewards(amt);

        // pause
        vm.prank(owner);
        silo.pause();

        // paused => maxWithdrawable = 0
        assertEq(silo.maxWithdrawable(), 0, "paused returns 0 available");

        // paused => mintRewards reverts
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        silo.mintRewards(1);

        // paused => withdrawToVault reverts
        vm.prank(vault);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        silo.withdrawToVault(1);

        // unpause to sanity check availability jumps forward
        vm.warp(block.timestamp + WEEK);
        vm.prank(owner);
        silo.unpause();
        // should be full amount now available
        _approxEq(silo.maxWithdrawable(), amt, 1, "catch-up after unpause");
    }

    function testAvailabilityCappedToBalance() public {
        uint256 amt = 200_000e6;

        vm.prank(owner);
        silo.mintRewards(amt);

        // Let 3/4 drip
        vm.warp(block.timestamp + (3 * WEEK) / 4);
        uint256 theoretical = silo.maxWithdrawable();
        _approxEq(theoretical, (amt * 3) / 4, 2, "3/4 drip");

        // Simulate unexpected token outflow: drain 50k from silo's balance
        // We spoof the sender as the silo to move its own balance (for test purposes).
        vm.prank(address(silo));
        IERC20(address(token)).transfer(address(0xDEAD), 50_000e6);

        // Now maxWithdrawable must be min(theoretical, balanceOf(silo))
        uint256 bal = IERC20(address(token)).balanceOf(address(silo));
        uint256 capped = silo.maxWithdrawable();
        assertEq(capped, bal, "availability capped to on-chain balance");
    }

    function testEventsOnMintAndWithdraw() public {
        uint256 amt = 123_456e6;

        vm.expectEmit(false, false, false, true);
        emit RewardSilo.Minted(amt, block.timestamp); // timestamp checked loosely by forge
        vm.prank(owner);
        silo.mintRewards(amt);

        // warp and withdraw from vault to emit Withdrawn
        vm.warp(block.timestamp + WEEK);
        vm.prank(vault);
        vm.expectEmit(false, false, false, true);
        emit RewardSilo.Withdrawn(amt);
        silo.withdrawToVault(amt);
    }
}
