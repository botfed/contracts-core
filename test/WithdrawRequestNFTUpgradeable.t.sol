// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WithdrawRequestNFTUpgradeable} from "../src/WithdrawRequestNFTUpgradeable.sol";

contract WithdrawRequestNFTUpagradeableTest is Test {
    WithdrawRequestNFTUpgradeable impl;
    WithdrawRequestNFTUpgradeable nft;

    address vault; // deployer (becomes immutable vault)
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address operator = makeAddr("operator");

    function setUp() public {
        // In this test, the test contract is the deployer -> vault
        vault = address(this);
        impl = new WithdrawRequestNFTUpgradeable();

        bytes memory initData = abi.encodeWithSelector(
            WithdrawRequestNFTUpgradeable.initialize.selector,
            "WithdrawRequest",
            "WRQ",
            vault, 
            owner
        );
        nft = WithdrawRequestNFTUpgradeable(address(new ERC1967Proxy(address(impl), initData)));
    }

    /* -------------------- constructor / immutables -------------------- */

    function test_VaultSetOnConstruction() public view {
        assertEq(nft.vault(), vault, "vault mismatch");
        assertEq(nft.name(), "WithdrawRequest");
        assertEq(nft.symbol(), "WRQ");
    }

    /* --------------------------- onlyVault --------------------------- */

    function test_MintOnlyVault() public {
        nft.mintTo(user1, 1);
        assertEq(nft.ownerOf(1), user1);
    }

    function test_Revert_MintFromNonVault() public {
        vm.prank(user1);
        vm.expectRevert(WithdrawRequestNFTUpgradeable.NotVault.selector);
        nft.mintTo(user1, 2);
    }

    function test_BurnOnlyVault() public {
        nft.mintTo(user1, 3);
        assertEq(nft.ownerOf(3), user1);

        // Non-vault cannot burn
        vm.prank(user1);
        vm.expectRevert(WithdrawRequestNFTUpgradeable.NotVault.selector);
        nft.burn(3);

        // Vault can burn
        nft.burn(3);
        vm.expectRevert(); // ownerOf reverts for non-existent token
        nft.ownerOf(3);
    }

    /* ---------------------- transfer restrictions --------------------- */

    function test_Revert_transferFromBlocked() public {
        nft.mintTo(user1, 10);

        // owner attempts transferFrom (blocked by override)
        vm.prank(user1);
        vm.expectRevert(bytes("non-transferable"));
        nft.transferFrom(user1, user2, 10);

        // even with approval, still blocked
        vm.prank(user1);
        nft.approve(operator, 10);
        vm.prank(operator);
        vm.expectRevert(bytes("non-transferable"));
        nft.transferFrom(user1, user2, 10);
    }

    /// NOTE: With current implementation, safeTransferFrom is NOT blocked.
    /// This test verifies the current behavior (token will transfer).
    function test_safeTransferFromBlocked_CurrentBehavior() public {
        nft.mintTo(user1, 11);
        assertEq(nft.ownerOf(11), user1);

        vm.startPrank(user1);
        vm.expectRevert(bytes("non-transferable"));
        nft.safeTransferFrom(user1, user2, 11); // succeeds
        vm.stopPrank();

        assertEq(nft.ownerOf(11), user1, "safeTransferFrom not transferred");
    }

    /* --------------------------- approvals --------------------------- */

    function test_ApprovalsCanBeSet_ButtransferFromStillBlocked() public {
        nft.mintTo(user1, 12);

        // setApprovalForAll
        vm.prank(user1);
        nft.setApprovalForAll(operator, true);
        assertTrue(nft.isApprovedForAll(user1, operator));

        // approve
        vm.prank(user1);
        nft.approve(operator, 12);
        assertEq(nft.getApproved(12), operator);

        // Despite approvals, transferFrom remains blocked
        vm.prank(operator);
        vm.expectRevert(bytes("non-transferable"));
        nft.transferFrom(user1, user2, 12);
    }
}
