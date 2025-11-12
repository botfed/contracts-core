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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISilo} from "./RewardSilo.sol";

/**
 * @title Pausable4626Vault
 * @notice Upgradeable ERC-4626 vault with pausing. Shares are ERC-20.
 * @dev UUPS upgradeable. Owner or RiskAdmin can pause/unpause deposit/mint/withdraw/redeem.
 */
contract sBotUSD is
    Initializable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    address public riskAdmin;
    ISilo public silo;

    event SiloSet(address indexed old, address indexed newAddr);
    event RiskAdminSet(address indexed old, address indexed newAddr);
    event PullFromSilo(uint256 requested, uint256 got);
    event SiloDrained(uint256 amount);
    event ZapBuy(address indexed caller, address indexed receiver, uint256 usdcIn, uint256 sharesOut);
    event ZapSell(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 sharesIn,
        uint256 usdcOut
    );

    /* ---------- errors ---------- */
    error Disabled();
    error Shortfall(uint256 needed, uint256 got);
    error ZeroAddress();
    error NotAuth();
    error SiloAssetMismatch();
    error InsufficientReceived(uint256 expected, uint256 got);
    error ZeroShares();
    error ZeroAssets();
    error ZeroAmount();

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
        address silo_
    ) public initializer {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        riskAdmin = initialOwner;

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setSilo(silo_);
    }

    /* ---- modifiers --- */

    modifier onlyRiskAdminOrOwner() {
        if (msg.sender != riskAdmin && msg.sender != owner()) revert NotAuth();
        _;
    }

    /*---- role setters ---- */

    function setSilo(address a) external onlyOwner whenPaused {
        _setSilo(a);
    }

    function _setSilo(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        address old = address(silo);
        silo = ISilo(a);
        if (address(silo.asset()) != address(asset())) revert SiloAssetMismatch();
        emit SiloSet(old, a);
    }

    function setRiskAdmin(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address old = riskAdmin;
        riskAdmin = a;
        emit RiskAdminSet(old, a);
    }

    // Risk admin functions

    function pause() external onlyRiskAdminOrOwner {
        _pause();
    }

    function unpause() external onlyRiskAdminOrOwner {
        _unpause();
    }
    /* ------ Convenience zaps --------*/
    // In StakingVault contract

    /**
     * @notice Buy sBotUSD with USDC in one transaction
     * @dev Zaps: USDC → BotUSD → sBotUSD
     * @param usdcAmount Amount of USDC to spend
     * @param receiver Address to receive sBotUSD
     * @return shares Amount of sBotUSD received
     */
    function zapBuy(uint256 usdcAmount, address receiver) external whenNotPaused nonReentrant returns (uint256 shares) {
        if (usdcAmount == 0) return 0;
        address baseVault = asset();
        IERC20 usdc = IERC20(ERC4626Upgradeable(baseVault).asset());

        // 1. Preview how many base vault shares we'll get
        uint256 expectedBaseShares = ERC4626Upgradeable(baseVault).previewDeposit(usdcAmount);
        if (expectedBaseShares == 0) revert ZeroShares();

        // 2. Preview how many sBotUSD shares user will get for those base shares
        shares = previewDeposit(expectedBaseShares);
        if (shares == 0) revert ZeroShares();

        // 3. Take USDC and deposit to base vault
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        usdc.forceApprove(baseVault, usdcAmount);
        uint256 baseShares = ERC4626Upgradeable(baseVault).deposit(usdcAmount, address(this));

        // 4. Verify we got expected amount (slippage check)
        require(baseShares >= expectedBaseShares, "Slippage");

        // 5. Mint sBotUSD
        uint256 maxAssets = maxDeposit(receiver);
        if (baseShares > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, baseShares, maxAssets);

        _mint(receiver, shares);

        emit Deposit(address(this), receiver, baseShares, shares);
        emit ZapBuy(msg.sender, receiver, usdcAmount, shares);
    }

    /**
     * @notice Sell sBotUSD for USDC in one transaction
     * @dev Zaps: sBotUSD → BotUSD → USDC
     * @param sBotUsdShares Amount of sBotUSD to sell
     * @param receiver Address to receive USDC
     * @param owner Owner of sBotUSD being redeemed
     * @return usdcAmount Amount of USDC received (after withdrawal fee)
     */
    function zapSell(
        uint256 sBotUsdShares,
        address receiver,
        address owner
    ) external whenNotPaused nonReentrant returns (uint256 usdcAmount) {
        if (sBotUsdShares == 0) return 0;
        // 1. Redeem sBotUSD for BotUSD
        uint256 botUsdAmount = _redeemInternal(sBotUsdShares, address(this), owner);
        if (botUsdAmount == 0) revert ZeroAssets();

        // 2. Redeem BotUSD for USDC (this handles withdrawal fee)
        IERC20(asset()).forceApprove(asset(), botUsdAmount);
        usdcAmount = ERC4626Upgradeable(asset()).redeem(botUsdAmount, receiver, address(this));
        if (usdcAmount == 0) revert ZeroAssets();

        emit ZapSell(msg.sender, receiver, owner, sBotUsdShares, usdcAmount);
    }

    /* ------------------------ ERC-4626 external functions ---------------------- */

    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        if (assets == 0) return 0;
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        shares = previewDeposit(assets);
        if (assets > 0 && shares == 0) revert ZeroShares();
        uint256 bal0 = IERC20(asset()).balanceOf(address(this));
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - bal0;
        if (received < assets) revert InsufficientReceived(assets, received);
        _mint(receiver, shares);
    }

    function maxDeposit(address account) public view override returns (uint256) {
        if (paused()) return 0;
        return type(uint256).max;
    }

    function mint(uint256 shares, address receiver) public pure override returns (uint256) {
        revert Disabled();
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant returns (uint256 assets) {
        return _redeemInternal(shares, receiver, owner_);
    }
    function _redeemInternal(uint256 shares, address receiver, address owner_) internal returns (uint256 assets) {
        if (shares == 0) return 0;
        uint256 maxShares = maxRedeem(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);
        assets = previewRedeem(shares);
        if (shares > 0 && assets == 0) revert ZeroAssets();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) _pullFromSilo(assets - bal);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function maxRedeem(address owner_) public view override returns (uint256 shares) {
        if (paused()) return 0;
        uint256 userShares = balanceOf(owner_);
        uint256 liqInShares = convertToShares(_availableLiquidity());
        return userShares < liqInShares ? userShares : liqInShares;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        if (assets == 0) return 0;
        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);
        shares = previewWithdraw(assets);
        if (assets > 0 && shares == 0) revert ZeroShares();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < assets) _pullFromSilo(assets - bal);
        _withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 userBal = convertToAssets(balanceOf(owner_));
        uint256 liq = _availableLiquidity();
        return userBal < liq ? userBal : liq;
    }

    function _availableLiquidity() internal view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (address(silo) == address(0)) return bal;
        uint256 m = silo.maxWithdrawable();
        unchecked {
            return bal + m;
        }
    }

    function _pullFromSilo(uint256 requested) internal {
        if (requested == 0) return;
        if (address(silo) == address(0)) revert ZeroAddress();
        uint256 b0 = IERC20(asset()).balanceOf(address(this));
        silo.withdrawToVault(requested);
        uint256 got = IERC20(asset()).balanceOf(address(this)) - b0;
        if (got < requested) revert Shortfall(requested, got);
        emit PullFromSilo(requested, got);
    }

    // Helper function in case of silo migration to avoid stranded funds.
    function drainFromSilo(uint256 amount) external onlyOwner whenPaused nonReentrant {
        _pullFromSilo(amount);
        emit SiloDrained(amount);
    }
    // Ops: pause → drain → setSilo → unpause

    // @dev totalAssets() = on-vault balance + silo.maxWithdrawable(), i.e., assets immediately available to this vault.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + (address(silo) != address(0) ? silo.maxWithdrawable() : 0);
    }

    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return IERC20Metadata(address(asset())).decimals();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* ----------------------------- Storage gap (future-proofing) --------------- */
    uint256[50] private __gap;
}
