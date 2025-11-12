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

/**
 * @notice Interface for StrategyManager that deploys capital to yield strategies
 * @dev The manager is responsible for:
 *      - Holding vault assets and deploying them to strategies
 *      - Tracking total withdrawable balance across all strategies
 *      - Handling withdrawal requests from the vault
 */
interface IStrategyManager {
    /**
     * @notice Returns the underlying asset managed by the StrategyManager
     * @dev Must match the vault's asset for safety
     * @return IERC20 address of the managed asset
     */
    function asset() external view returns (IERC20);

    /**
     * @notice Returns total amount withdrawable from all strategies
     * @dev Used by vault to calculate available liquidity
     * @return Total withdrawable balance across strategies
     */
    function maxWithdrawable() external view returns (uint256);

    /**
     * @notice Withdraws specified amount from strategies back to vault
     * @dev Called by vault when liquidity is needed for redemptions
     * @param amount Amount to withdraw to vault
     */
    function withdrawToVault(uint256 amount) external;
}

/**
 * @title BotUSD
 * @author BotFed Protocol
 * @notice Yield-bearing stablecoin backed 1:1 by USDC with DeFi yield strategies
 * @dev ERC-4626 compliant upgradeable vault with pausability, whitelisting, and reward minting
 *
 * ## Overview
 * BotUSD is a yield-generating stablecoin that maintains 1:1 backing with USDC while
 * deploying capital to DeFi yield strategies. The protocol generates yield through:
 * - Liquidity provision on DEXs (Aerodrome, Velodrome)
 * - Lending protocols (Moonwell, Aave)
 * - Perpetual trading strategies (Hyperliquid, Avantis)
 * - Yield optimization (Pendle)
 *
 * ## Key Features
 * - **1:1 Backing**: totalAssets() always equals totalSupply() for price stability
 * - **Yield Distribution**: Profits are minted as inflationary rewards for stakers
 * - **Capital Efficiency**: Assets deployed to StrategyManager for yield generation
 * - **Loss Absorption**: Burn mechanism allows stabilization fund to absorb losses
 * - **Access Control**: Whitelist and TVL caps for controlled growth
 * - **Upgradeability**: UUPS pattern for protocol improvements
 *
 * ## Architecture
 * BotUSD Vault (this) → StrategyManager → Multiple DeFi Strategies
 *                    ↓
 *                RewardSilo → StakingVault (sBotUSD)
 *
 * ## Security Model
 * - Owner: Can pause, upgrade, change manager/rewarder
 * - RiskAdmin: Can pause, adjust TVL caps, manage whitelist
 * - Rewarder: Can mint inflationary rewards (rate-limited)
 * - Users: Can deposit/withdraw when whitelisted (if active)
 */
contract BotUSD is
    Initializable,
    ERC4626Upgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ========== */

    /**
     * @notice Maximum inflation per mint in basis points (5%)
     * @dev Caps reward minting to prevent excessive inflation
     *      5% per week = ~260% APY maximum
     *      Generous enough for exceptional performance while maintaining trust
     */
    uint256 public constant MAX_INFLATION_PER_MINT_BIPS = 500;
    /// @notice Maximum allowed withdrawal fee (100 = 1%)
    uint256 public constant MAX_WITHDRAWAL_FEE_BIPS = 100;

    /**
     * @notice Minimum time between reward mints (1 week)
     * @dev Prevents rapid repeated inflation
     *      Forces reasonable distribution frequency
     */
    uint256 public constant MIN_WAIT_MINT_SECONDS = 7 days;

    /* ========== STATE VARIABLES ========== */

    /// @dev Deprecated: Previously used for withdraw NFT system
    address public deprecated_withdrawNFT;

    /// @dev Deprecated: Previously used for fulfill withdraw requests
    address public deprecated_fulfiller;

    /**
     * @notice Risk administrator with emergency powers
     * @dev Can pause vault and adjust risk parameters (TVL cap, whitelist)
     *      Intended for rapid response to risks without full owner privileges
     */
    address public riskAdmin;

    /**
     * @notice StrategyManager that deploys vault assets to yield strategies
     * @dev Holds vault assets and manages capital allocation
     *      Must have matching asset() for safety
     */
    IStrategyManager public manager;

    // State variable (reuse deprecated slot)
    /// @notice Address that receives withdrawal fees
    address public feeReceiver;

    /**
     * @notice RewardSilo address authorized to mint inflationary rewards
     * @dev Mints BotUSD based on protocol profits for staking incentives
     *      Subject to MAX_INFLATION_PER_MINT_BIPS and MIN_WAIT_MINT_SECONDS limits
     */
    address public rewarder;

    /**
     * @notice Maximum total value locked (in BotUSD units)
     * @dev Caps total supply to manage risk during growth phase
     *      Set to type(uint256).max to disable
     */
    uint256 public tvlCap;

    /**
     * @notice Whether user whitelist is active
     * @dev When true, only whitelisted addresses can deposit/withdraw
     *      Used for controlled launch and regulatory compliance
     */
    bool public userWhitelistActive;

    /**
     * @notice Mapping of whitelisted user addresses
     * @dev Only relevant when userWhitelistActive is true
     */
    mapping(address => bool) public userWhitelist;

    /// @dev Deprecated: Previously used for tracking withdraw requests
    mapping(uint256 => uint256) public deprecated_requests;

    /// @dev Deprecated: Previously used for request ID tracking
    uint256 public deprecated_nextReqId;

    /// @dev Deprecated: Previously used for total requested amount tracking
    uint256 public deprecated_amtRequested;

    /**
     * @notice Timestamp of last reward mint
     * @dev Used to enforce MIN_WAIT_MINT_SECONDS cooldown
     *      Starts at 0, allowing immediate first mint
     */
    uint256 public lastRewardMintTime;

    /// @notice Withdrawal fee in basis points (25 = 0.25%)
    uint256 public withdrawalFeeBips;

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when StrategyManager address is updated
     * @param old Previous manager address
     * @param newAddr New manager address
     */
    event ManagerSet(address indexed old, address indexed newAddr);

    /**
     * @notice Emitted when risk admin address is updated
     * @param old Previous risk admin address
     * @param newAddr New risk admin address
     */
    event RiskAdminSet(address indexed old, address indexed newAddr);

    /**
     * @notice Emitted when rewarder address is updated
     * @param old Previous rewarder address
     * @param newAddr New rewarder address
     */
    event RewarderSet(address indexed old, address indexed newAddr);

    /**
     * @notice Emitted when capital is deployed to StrategyManager
     * @param strat Manager address that received capital
     * @param amount Amount of assets deployed
     */
    event CapitalDeployed(address strat, uint256 amount);

    /**
     * @notice Emitted when liquidity is pulled from StrategyManager
     * @param request Amount requested
     * @param got Amount actually received
     */
    event LiquidityPulled(uint256 request, uint256 got);

    /**
     * @notice Emitted when user whitelist status changes
     * @param user Address whose status changed
     * @param isWhitelisted New whitelist status
     */
    event UserWhitelist(address indexed user, bool isWhitelisted);

    /**
     * @notice Emitted when whitelist activation status changes
     * @param isActive Whether whitelist is now active
     */
    event UserWhitelistActive(bool isActive);

    /**
     * @notice Emitted when TVL cap is updated
     * @param newCap New TVL cap value
     */
    event TVLCapChanged(uint256 newCap);

    /**
     * @notice Emitted when rewards are minted
     * @param to Address that received minted rewards (rewarder)
     * @param amount Amount of BotUSD minted
     * @param timestamp Block timestamp of mint
     */
    event RewardsMinted(address indexed to, uint256 amount, uint256 timestamp);

    /**
     * @notice Emitted when BotUSD is burned
     * @param from Address that burned tokens
     * @param amount Amount of BotUSD burned
     */
    event Burned(address indexed from, uint256 amount);

    event WithdrawalFeeChanged(uint256 newFeeBips);
    event FeeReceiverSet(address indexed oldReceiver, address indexed newReceiver);
    error ZeroShares();

    /* ========== ERRORS ========== */

    /// @notice Thrown when calling disabled mint() function
    error Disabled();

    /// @notice Thrown when manager cannot provide requested liquidity
    error Shortfall(uint256 needed, uint256 got);

    /// @notice Thrown when zero address provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when caller lacks required authorization
    error NotAuth();

    /// @notice Thrown when trying to mint rewards before cooldown expires
    error MintTooSoon();

    /// @notice Thrown when mint amount exceeds MAX_INFLATION_PER_MINT_BIPS
    error MintExceedsLimit();

    error FeeTooHigh();
    error InsufficientReceived(uint256 expected, uint256 received);

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    /**
     * @notice Initializes the BotUSD vault
     * @dev Can only be called once due to initializer modifier
     *      Sets up ERC-4626 vault with 1:1 USDC backing
     *
     * @param asset_ Underlying asset (USDC)
     * @param name_ Token name (e.g., "BotUSD")
     * @param symbol_ Token symbol (e.g., "botUSD")
     * @param initialOwner Owner address with full admin privileges
     * @param manager_ StrategyManager address for yield generation
     * @param rewarder_ RewardSilo address (can be zero initially)
     *
     * Initial state:
     * - TVL cap: unlimited (type(uint256).max)
     * - Whitelist: active (restricted access)
     * - Risk admin: same as owner
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address manager_,
        address rewarder_
    ) public initializer {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();

        rewarder = rewarder_;
        riskAdmin = initialOwner;
        tvlCap = type(uint256).max;
        userWhitelistActive = true;

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setManager(manager_);
    }

    /* ========== MODIFIERS ========== */

    /**
     * @notice Restricts function to owner or risk admin
     * @dev Used for risk management functions that need rapid response
     */
    modifier onlyRiskAdminOrOwner() {
        if (msg.sender != riskAdmin && msg.sender != owner()) revert NotAuth();
        _;
    }

    /**
     * @notice Restricts function to authorized rewarder
     * @dev Only RewardSilo can mint inflationary rewards
     */
    modifier onlyRewarder() {
        if (msg.sender != rewarder) revert NotAuth();
        _;
    }

    /**
     * @notice Restricts function to whitelisted users when whitelist active
     * @dev Allows permissionless access when whitelist is disabled
     */
    modifier onlyWhitelisted() {
        if (userWhitelistActive && !userWhitelist[msg.sender]) revert NotAuth();
        _;
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Updates the StrategyManager address
     * @dev Only callable by owner when paused for safety
     *      Manager must have matching asset() for compatibility
     *
     * @param a New manager address
     *
     * Requirements:
     * - Caller must be owner
     * - Contract must be paused
     * - New manager's asset must match vault's asset
     */
    function setManager(address a) external onlyOwner whenPaused {
        _setManager(a);
    }

    /**
     * @notice Internal function to set manager with validation
     * @param a New manager address
     */
    function _setManager(address a) internal {
        if (a == address(0)) revert ZeroAddress();
        address old = address(manager);
        manager = IStrategyManager(a);
        require(address(manager.asset()) == address(asset()), "A");
        emit ManagerSet(old, a);
    }

    /**
     * @notice Updates the risk admin address
     * @dev Risk admin can pause and adjust risk parameters
     *
     * @param a New risk admin address
     *
     * Requirements:
     * - Caller must be owner
     * - New address must not be zero
     */
    function setRiskAdmin(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address old = riskAdmin;
        riskAdmin = a;
        emit RiskAdminSet(old, a);
    }

    /**
     * @notice Updates the rewarder address
     * @dev Rewarder (RewardSilo) can mint inflationary rewards
     *
     * @param a New rewarder address
     *
     * Requirements:
     * - Caller must be owner
     * - New address must not be zero
     */
    function setRewarder(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address old = rewarder;
        rewarder = a;
        emit RewarderSet(old, a);
    }
    // Setter
    function setFeeReceiver(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address old = feeReceiver;
        feeReceiver = a;
        emit FeeReceiverSet(old, a);
    }

    function setWithdrawalFee(uint256 feeBips) external onlyOwner {
        if (feeReceiver == address(0)) revert ZeroAddress();
        if (feeBips > MAX_WITHDRAWAL_FEE_BIPS) revert FeeTooHigh();
        withdrawalFeeBips = feeBips;
        emit WithdrawalFeeChanged(feeBips);
    }

    /* ========== RISK PARAMETER SETTERS ========== */

    /**
     * @notice Updates whitelist status for a user
     * @dev Can be called by owner or risk admin for operational flexibility
     *
     * @param a User address
     * @param isWhitelisted Whether user should be whitelisted
     */
    function setUserWhitelist(address a, bool isWhitelisted) external onlyRiskAdminOrOwner {
        userWhitelist[a] = isWhitelisted;
        emit UserWhitelist(a, isWhitelisted);
    }

    /**
     * @notice Enables or disables the whitelist system
     * @dev When disabled, all users can deposit/withdraw
     *
     * @param b Whether whitelist should be active
     */
    function setUserWhitelistActive(bool b) external onlyRiskAdminOrOwner {
        userWhitelistActive = b;
        emit UserWhitelistActive(b);
    }

    /**
     * @notice Updates the TVL cap
     * @dev Use type(uint256).max to disable cap
     *
     * @param newCap New maximum total supply
     */
    function setTVLCap(uint256 newCap) external onlyRiskAdminOrOwner {
        tvlCap = newCap;
        emit TVLCapChanged(tvlCap);
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Checks if address is whitelisted
     * @param a Address to check
     * @return Whether address is whitelisted
     */
    function userIsWhitelisted(address a) external view returns (bool) {
        return userWhitelist[a];
    }

    /* ========== PAUSE CONTROL ========== */

    /**
     * @notice Pauses all deposits, withdrawals, and minting
     * @dev Emergency stop mechanism for security incidents
     */
    function pause() external onlyRiskAdminOrOwner {
        _pause();
    }

    /**
     * @notice Unpauses the vault
     * @dev Re-enables normal operations
     */
    function unpause() external onlyRiskAdminOrOwner {
        _unpause();
    }

    /* ========== ERC-4626 FUNCTIONS ========== */

    /**
     * @notice Deposits assets and mints shares 1:1
     * @dev Overrides ERC4626 to:
     *      - Enforce whitelist if active
     *      - Protect against fee-on-transfer tokens
     *      - Immediately deploy capital to StrategyManager
     *
     * @param assets Amount of USDC to deposit
     * @param receiver Address to receive BotUSD shares
     * @return shares Amount of BotUSD minted (equals assets due to 1:1)
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must be whitelisted (if whitelist active)
     * - Must not exceed TVL cap
     * - Manager must be set
     * - Must receive full asset amount (no fee-on-transfer)
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant onlyWhitelisted returns (uint256 shares) {
        if (address(manager) == address(0)) revert ZeroAddress();
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);

        shares = previewDeposit(assets);
        // Prevent donations for small amounts or inflation attack
        if (shares == 0) revert ZeroShares();

        // Verify full amount received (protect against fee-on-transfer tokens)
        uint256 bal0 = IERC20(asset()).balanceOf(address(this));
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - bal0;
        if (received < assets) revert InsufficientReceived(assets, received);

        // Deploy capital immediately to StrategyManager
        _pushToManager(received);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Returns maximum deposit amount for account
     * @dev Considers pause status, whitelist, and TVL cap
     *
     * @param account Address to check deposit limit for
     * @return Maximum depositable amount
     */
    function maxDeposit(address account) public view override returns (uint256) {
        if (paused()) return 0;
        if (userWhitelistActive && !userWhitelist[account]) return 0;
        if (tvlCap < totalSupply()) return 0;
        if (tvlCap < type(uint256).max) return tvlCap - totalSupply();
        return type(uint256).max;
    }

    /**
     * @notice Disabled mint function
     * @dev Users should use deposit() instead for clarity
     *      Prevents confusion about share vs asset amounts
     */
    function mint(uint256, address) public pure override returns (uint256) {
        revert Disabled();
    }

    /**
     * @notice Returns maximum mintable shares (always 0)
     * @dev Mint function is disabled
     */
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Mints inflationary rewards for staking incentives
     * @dev Only callable by authorized rewarder (RewardSilo)
     *      Subject to rate limits for security:
     *      - Max 5% of total supply per mint
     *      - Minimum 1 week between mints
     *
     * @param amount Amount of BotUSD to mint
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must be rewarder
     * - Must wait MIN_WAIT_MINT_SECONDS since last mint
     * - Amount must not exceed MAX_INFLATION_PER_MINT_BIPS
     *
     * Note: Minted tokens are sent to rewarder (RewardSilo) which
     *       drips them to StakingVault over time
     */
    function mintRewards(uint256 amount) external onlyRewarder whenNotPaused nonReentrant {
        if (block.timestamp < lastRewardMintTime + MIN_WAIT_MINT_SECONDS) {
            revert MintTooSoon();
        }
        if (amount * 10_000 > totalSupply() * MAX_INFLATION_PER_MINT_BIPS) {
            revert MintExceedsLimit();
        }

        lastRewardMintTime = block.timestamp;
        _mint(rewarder, amount);
        emit RewardsMinted(rewarder, amount, block.timestamp);
    }

    /**
     * @notice Redeems shares for assets 1:1
     * @dev Pulls liquidity from StrategyManager if needed
     *
     * @param shares Amount of BotUSD to redeem
     * @param receiver Address to receive USDC
     * @param owner_ Owner of shares being redeemed
     * @return assetsAfterFee Amount of USDC withdrawn (equals shares due to 1:1)
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must be whitelisted (if whitelist active)
     * - Must have approval if caller != owner
     * - Sufficient liquidity must be available
     **/

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) public override whenNotPaused nonReentrant onlyWhitelisted returns (uint256 assetsAfterFee) {
        uint256 maxShares = maxRedeem(owner_);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);

        // Get gross assets corresponding to `shares` from the base ERC4626 logic
        uint256 gross = super.previewRedeem(shares); // avoids our override

        uint256 fee = withdrawalFeeBips == 0 ? 0 : (gross * withdrawalFeeBips) / 10_000;
        assetsAfterFee = gross - fee;

        // Ensure we have enough liquidity to cover gross (net + fee)
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (bal < gross) _pullFromManager(gross - bal);

        // Burn exactly `shares`, pay the receiver the net
        _withdraw(msg.sender, receiver, owner_, assetsAfterFee, shares);
        // Route fee if configured (else it remains in the vault)
        if (fee > 0 && feeReceiver != address(0)) {
            IERC20(asset()).safeTransfer(feeReceiver, fee);
        }
    }

    // Fee-aware preview: returns net to receiver for a given `shares`
    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        uint256 gross = super.previewRedeem(shares); // base 4626 value
        if (withdrawalFeeBips == 0) return gross;
        uint256 fee = (gross * withdrawalFeeBips) / 10_000;
        return gross - fee;
    }

    /**
     * @notice Returns maximum redeemable shares for owner
     * @dev Limited by both user balance and available liquidity
     *
     * @param owner_ Address to check redemption limit for
     * @return Maximum redeemable shares
     */
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
        revert Disabled();
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        return 0;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return 0;
    }

    /**
     * @notice Returns total assets backing the vault
     * @dev Always equals totalSupply() to enforce 1:1 backing
     *      This is the core mechanism ensuring BotUSD = 1 USDC
     *
     * @return Total assets (equal to total supply)
     *
     * Note: Does NOT include assets in StrategyManager in this calculation
     *       because those are already accounted for in totalSupply().
     *       The 1:1 invariant is: totalSupply() = initial_deposits - losses
     */
    function totalAssets() public view override returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Calculates total liquidity available for withdrawals
     * @dev Sum of vault balance and manager withdrawable amount
     *
     * @return Total available liquidity
     */
    function _availableLiquidity() internal view returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (address(manager) == address(0)) return bal;
        uint256 m = manager.maxWithdrawable();
        unchecked {
            return bal + m;
        }
    }

    /**
     * @notice Returns token decimals (matches underlying asset)
     * @dev Typically 6 for USDC
     *
     * @return Number of decimals
     */
    function decimals() public view override(ERC4626Upgradeable) returns (uint8) {
        return IERC20Metadata(address(asset())).decimals();
    }

    /* ========== LOSS ABSORPTION ========== */

    /**
     * @notice Burns BotUSD from caller's balance
     * @dev Used by stabilization fund to absorb strategy losses
     *      and maintain 1:1 backing
     *
     * Example: If strategies lose 100k USDC, stabilization fund
     *          burns 100k BotUSD to restore 1:1 ratio
     *
     * @param amount Amount of BotUSD to burn
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must have sufficient balance
     */
    function burn(uint256 amount) external whenNotPaused nonReentrant {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
     * @notice Deploys capital to StrategyManager
     * @dev Called automatically on deposits
     *
     * @param amt Amount to deploy
     */
    function _pushToManager(uint256 amt) internal {
        if (address(manager) == address(0)) revert ZeroAddress();
        IERC20(address(asset())).safeTransfer(address(manager), amt);
        emit CapitalDeployed(address(manager), amt);
    }

    /**
     * @notice Pulls liquidity from StrategyManager
     * @dev Called when vault needs funds for withdrawals
     *
     * @param needed Amount needed
     *
     * Requirements:
     * - Manager must provide at least the requested amount
     */
    function _pullFromManager(uint256 needed) internal {
        if (needed == 0) return;
        require(address(manager) != address(0), "manager not set");

        uint256 b0 = IERC20(asset()).balanceOf(address(this));
        manager.withdrawToVault(needed);
        uint256 got = IERC20(asset()).balanceOf(address(this)) - b0;

        if (got < needed) revert Shortfall(needed, got);
        emit LiquidityPulled(needed, got);
    }

    /* ========== UPGRADE AUTHORIZATION ========== */

    /**
     * @notice Authorizes contract upgrades
     * @dev Only callable by owner. Part of UUPS upgrade pattern.
     *
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* ========== STORAGE GAP ========== */

    /**
     * @dev Storage gap for future upgrades
     * Original: 50 slots
     * Used: 2 slots for lastRewardMintTime, withdrawalFeeBips (Nov 10 2025)
     * Remaining: 48 slots
     */
    uint256[48] private __gap;
}
