// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* OpenZeppelin Upgradeable */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";


interface IWithdrawRequestNFT is IERC721 {
    function mintTo(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}





/**
 * @title WithdrawRequestNFTUpgradeable
 * @notice Upgradeable, non-transferable ERC-721 used as a claim ticket for withdrawal requests.
 *         The `vault` is set at initialization and is the only address allowed to mint/burn.
 */
contract WithdrawRequestNFTUpgradeable is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC721Upgradeable
{
    /// @custom:error NonTransferable
    error NonTransferable();
    /// @custom:error NotVault
    error NotVault();
    /// @custom:error ZeroAddress()

    address public vault; // set during initialize; NOT immutable in upgradeable patterns

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the proxy.
     * @param name_   ERC-721 name
     * @param symbol_ ERC-721 symbol
     * @param vault_  Address authorized to mint/burn
     * @param owner_  Contract owner (upgrade admin)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address vault_,
        address owner_
    ) public initializer {
        if (vault_ == address(0) || owner_ == address(0)) revert();

        __ERC721_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __Ownable_init(owner_);

        vault = vault_;
    }

    /* ---------- disable transfers ---------- */
    function transferFrom(address, address, uint256) public virtual override {
        revert("non-transferable");
    }

    /* ------------------------------ Mint / Burn ----------------------------- */

    function mintTo(address to, uint256 tokenId) external onlyVault {
        _safeMint(to, tokenId);
    }

    function burn(uint256 tokenId) external onlyVault {
        _burn(tokenId);
    }

    /* --------------------------- UUPS authorization ------------------------- */
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* ------------------------------- Storage gap ---------------------------- */
    uint256[49] private __gap;
}
