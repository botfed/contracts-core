// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title WithdrawRequestNFT
 * @notice Non-upgradeable ERC-721 used as a claim ticket for withdrawal requests.
 *         The deploying contract becomes the immutable `vault` and is the only
 *         address allowed to mint/burn.
 */
contract WithdrawRequestNFT is ERC721 {
    address public immutable vault;

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) {
        vault = msg.sender; // the vault that deploys this contract
    }

    modifier onlyVault() {
        require(msg.sender == vault, "not vault");
        _;
    }
    /* ---------- disable transfers ---------- */
    function transferFrom(address, address, uint256) public virtual override {
        revert("non-transferable");
    }

    function mintTo(address to, uint256 tokenId) external onlyVault {
        _safeMint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyVault {
        _burn(tokenId);
    }
}
