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

    address public riskAdmin;
    IStrategyManager public manager;

    // restrictions on users and tvl
    uint256 public tvlCap;
    bool public userWhiteListActive;
    mapping(address => bool) public userWhiteList;

    /* -- Strategy functions --- */
    event ManagerSet(address indexed a);
    event RiskAdminSet(address indexed a);
    event CapitalDeployed(address strat, uint256 amount);
    event LiquidityPulled(uint256 request, uint256 got);
    event UserWhiteList(address indexed user, bool isWhiteListed);
    event UserWhiteListActive(bool isActive);
    event TVLCapChanged(uint256 newCap);

    /* ---------- errors ---------- */
    error Disabled();
    error Shortfall(uint256 needed, uint256 got);

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
        userWhiteListActive = true;

        // Initialize parent contracts
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _setManager(manager_);
    }

    /*---- setters ---- */

    function setManager(address a) external onlyOwner whenPaused {
        _setManager(a);
    }

    function _setManager(address a) internal {
        require(a != address(0), "ZM");
        manager = IStrategyManager(a);
        require(address(manager.asset()) == address(asset()), "A");
        emit ManagerSet(a);
    }

    function setRiskAdmin(address a) external onlyOwner {
        require(a != address(0), "ZRA");
        riskAdmin = a;
        emit RiskAdminSet(a);
    }
    function setUserWhiteList(address a, bool isWhiteListed) external onlyRiskAdminOrGov {
        userWhiteList[a] = isWhiteListed;
        emit UserWhiteList(a, isWhiteListed);
    }

    function setUserWhiteListActive(bool b) external onlyRiskAdminOrGov {
        userWhiteListActive = b;
        emit UserWhiteListActive(b);
    }

    function setTVLCap(uint256 newCap) external onlyRiskAdminOrGov {
        tvlCap = newCap;
        emit TVLCapChanged(tvlCap);
    }

    /* -- some getters */
    function userIsWhitelisted(address a) external view returns (bool) {
        return userWhiteList[a];
    }

    /* ---- modifiers --- */

    modifier onlyRiskAdminOrGov() {
        require(msg.sender == riskAdmin || msg.sender == owner(), "ORA");
        _;
    }
    modifier onlyWhiteListed() {
        require(!userWhiteListActive || userWhiteList[msg.sender], "OWL");
        _;
    }

    function _pushToManager(uint256 amt) internal {
        require(address(manager) != address(0), "PM");
        IERC20(address(asset())).safeTransfer(address(manager), amt);
        emit CapitalDeployed(address(manager), amt);
    }

    /* ----------------------------- Pausing control ----------------------------- */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ------------------------ ERC-4626 external functions ---------------------- */
    // Block state-changing flows while paused; view/preview functions remain available.

    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant onlyWhiteListed returns (uint256 shares) {
        require(address(manager) != address(0), "manager not set");
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        // 1:1 → shares == assets
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        (shares, ) = _exit(assets, 0, receiver, owner_);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant returns (uint256 assets) {
        (, assets) = _exit(0, shares, receiver, owner_);
    }
    /* internals */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        uint256 bal0 = IERC20(asset()).balanceOf(address(this));
        // pull assets in
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - bal0;
        require(received == assets, "RAM");
        // kick capital to manager
        _pushToManager(received);
        // mint shares
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
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

    function _availableLiquidity() internal view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (address(manager) == address(0)) return bal;
        uint256 m = manager.maxWithdrawable();
        // Defensive: avoid accidental overflow (not realistically hit with ERC20)
        unchecked {
            return bal + m;
        }
    }

    function _exit(
        uint256 assets, // set if withdraw path; may be 0 on redeem path
        uint256 shares, // set if redeem path; may be 0 on withdraw path
        address receiver,
        address owner_
    ) internal returns (uint256 sharesBurned, uint256 assetsOut) {
        // 0-amount operations: make them a no-op (many integrators probe with 0)
        if (assets == 0 && shares == 0) {
            return (0, 0);
        }

        if (assets == 0 && shares != 0) {
            // redeem path
            assets = previewRedeem(shares);
            uint256 maxS = maxRedeem(owner_);
            if (shares > maxS) revert ERC4626ExceededMaxRedeem(owner_, shares, maxS);
        } else if (shares == 0 && assets != 0) {
            // withdraw path
            shares = previewWithdraw(assets);
            uint256 maxA = maxWithdraw(owner_);
            if (assets > maxA) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxA);
        } else {
            // both provided (shouldn't happen via your externals, but defend anyway)
            // ensure consistency under current exchange rate
            uint256 expectedAssets = previewRedeem(shares);
            require(expectedAssets == assets, "exit: assets/shares mismatch");
            uint256 maxA2 = maxWithdraw(owner_);
            if (assets > maxA2) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxA2);
        }

        // Ensure liquidity before internal withdraw
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) _pullFromManager(assets - bal);

        // Single standard path
        _withdraw(_msgSender(), receiver, owner_, assets, shares);
        return (shares, assets);
    }

    // CPPS accounting: principal only. If you externalize yield, keep this equal to principal.
    function totalAssets() public view override returns (uint256) {
        // simplest CPPS invariant: principal == totalSupply()
        return totalSupply();
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        // User can’t withdraw more than their balance (1:1 shares/assets)
        uint256 userBal = convertToAssets(balanceOf(owner_)); // == balanceOf(owner_)
        uint256 liq = _availableLiquidity();
        // Min(user balance, available liquidity)
        return userBal < liq ? userBal : liq;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 userShares = balanceOf(owner_); // 1:1, so this equals assets
        uint256 liq = _availableLiquidity();
        // Since shares==assets, the same min applies
        return userShares < liq ? userShares : liq;
    }

    // Disable share-centric entry
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function maxDeposit(address account) public view override returns (uint256) {
        if (paused()) return 0;
        if (userWhiteListActive && !userWhiteList[account]) return 0;
        if (tvlCap < totalSupply()) return 0;
        if (tvlCap < type(uint256).max) return tvlCap - totalSupply();
        return type(uint256).max;
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert Disabled();
    }

    // Match share decimals to the underlying asset
    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return IERC20Metadata(address(asset())).decimals();
    }


    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* ----------------------------- Storage gap (future-proofing) --------------- */
    uint256[50] private __gap;
}
