// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* OpenZeppelin Upgradeable */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyManager} from "./StrategyManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Pausable4626Vault
 * @notice Upgradeable ERC-4626 vault with pausing. Shares are ERC-20.
 * @dev UUPS upgradeable. Owner can pause/unpause deposit/mint/withdraw/redeem.
 */
contract Pausable4626Vault is
    Initializable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    address public deprecated_withdrawNFT;
    address public deprecated_fulfiller;
    address public riskAdmin;
    IStrategyManager public manager;
    address public deprecated_minter;
    address public deprecated_rewarder;

    // restrictions on users and tvl
    uint256 public tvlCap;
    bool public userWhitelistActive;
    mapping(address => bool) public userWhitelist;

    mapping(uint256 => uint256) public deprecated_requests;
    uint256 public deprecated_nextReqId;
    uint256 public deprecated_amtRequested;

    /* -- Strategy functions --- */
    event ManagerSet(address indexed a);
    event RiskAdminSet(address indexed a);
    event CapitalDeployed(address strat, uint256 amount);
    event LiquidityPulled(uint256 request, uint256 got);
    event UserWhitelist(address indexed user, bool isWhitelisted);
    event UserWhitelistActive(bool isActive);
    event TVLCapChanged(uint256 newCap);

    /* ---------- errors ---------- */
    error Disabled();
    error Shortfall(uint256 needed, uint256 got);
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // UUPS pattern safeguard
    }

    /**
     * @param asset_        Underlying ERC-20 asset the vault accepts (e.g., USDC)
     * @param name_         Share token name
     * @param symbol_       Share token symbol
     * @param initialOwner  Owner address (can pause/unpause and authorize upgrades)
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address manager_
    ) public initializer {
        if (address(asset_) == address(0)) revert(); // asset must be set
        if (initialOwner == address(0)) revert(); // owner must be set

        riskAdmin = initialOwner;
        tvlCap = type(uint256).max;
        userWhitelistActive = true;

        // Initialize parent contracts
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setManager(manager_);
    }

    /* ---- modifiers --- */

    modifier onlyRiskAdminOrOwner() {
        require(msg.sender == riskAdmin || msg.sender == owner(), "ORA");
        _;
    }
    modifier onlyWhitelisted() {
        require(!userWhitelistActive || userWhitelist[msg.sender], "OWL");
        _;
    }

    /*---- role setters ---- */

    function setManager(address a) external onlyOwner whenPaused {
        _setManager(a);
    }

    function _setManager(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        manager = IStrategyManager(a);
        require(address(manager.asset()) == address(asset()), "A");
        emit ManagerSet(a);
    }

    function setRiskAdmin(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        riskAdmin = a;
        emit RiskAdminSet(a);
    }

    /*-- parameter setters --- */

    function setUserWhitelist(address a, bool isWhitelisted) external onlyRiskAdminOrOwner {
        userWhitelist[a] = isWhitelisted;
        emit UserWhitelist(a, isWhitelisted);
    }

    function setUserWhitelistActive(bool b) external onlyRiskAdminOrOwner {
        userWhitelistActive = b;
        emit UserWhitelistActive(b);
    }

    function setTVLCap(uint256 newCap) external onlyRiskAdminOrOwner {
        tvlCap = newCap;
        emit TVLCapChanged(tvlCap);
    }

    /* -- some getters */
    function userIsWhitelisted(address a) external view returns (bool) {
        return userWhitelist[a];
    }

    /* ----------------------------- Pausing control ----------------------------- */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ------------------------ ERC-4626 external functions ---------------------- */

    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant onlyWhitelisted returns (uint256 shares) {
        require(address(manager) != address(0), "manager not set");
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        // 1:1 → shares == assets
        shares = previewDeposit(assets);
        // Check we receive the assets
        uint256 bal0 = IERC20(asset()).balanceOf(address(this));
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - bal0;
        require(received >= assets, "RAM");
        _pushToManager(received);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxDeposit(address account) public view override returns (uint256) {
        if (paused()) return 0;
        if (userWhitelistActive && !userWhitelist[account]) return 0;
        if (tvlCap < totalSupply()) return 0;
        if (tvlCap < type(uint256).max) return tvlCap - totalSupply();
        return type(uint256).max;
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert Disabled();
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant onlyWhitelisted returns (uint256 assets) {
        uint256 maxShares = maxRedeem(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);
        // 1:1 assets to shares
        assets = previewRedeem(shares);
        // Ensure liquidity before internal withdraw
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) _pullFromManager(assets - bal);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 userShares = balanceOf(owner_);
        uint256 liqInShares = convertToShares(_availableLiquidity());
        return userShares < liqInShares ? userShares : liqInShares;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant onlyWhitelisted returns (uint256 shares) {
        // withdraw path
        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);
        shares = previewWithdraw(assets);
        // Ensure liquidity before internal withdraw
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) _pullFromManager(assets - bal);
        // Single standard path
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        // User can’t withdraw more than their balance (1:1 shares/assets)
        uint256 userBal = convertToAssets(balanceOf(owner_)); // == balanceOf(owner_)
        uint256 liq = _availableLiquidity();
        // Min(user balance, available liquidity)
        return userBal < liq ? userBal : liq;
    }

    function totalAssets() public view override returns (uint256) {
        // simplest CPPS invariant: principal == totalSupply()
        return totalSupply();
    }

    function _availableLiquidity() internal view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (address(manager) == address(0)) return bal;
        uint256 m = manager.maxWithdrawable();
        // Defensive: avoid accidental overflow (not realistically hit with ERC20)
        unchecked {
            return bal + m;
        }
    }

    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return IERC20Metadata(address(asset())).decimals();
    }

    function _pushToManager(uint256 amt) internal {
        if (address(manager) == address(0)) revert ZeroAddress();
        IERC20(address(asset())).safeTransfer(address(manager), amt);
        emit CapitalDeployed(address(manager), amt);
    }

    function _pullFromManager(uint256 needed) internal {
        if (needed == 0) return;
        require(address(manager) != address(0), "manager not set");
        uint256 b0 = IERC20(asset()).balanceOf(address(this));
        manager.withdrawToVault(needed);
        uint256 got = IERC20(asset()).balanceOf(address(this)) - b0;
        if (got < needed) revert Shortfall(needed, got);
        emit LiquidityPulled(needed, got);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* ----------------------------- Storage gap (future-proofing) --------------- */
    uint256[50] private __gap;
}
