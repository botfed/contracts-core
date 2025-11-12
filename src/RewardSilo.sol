// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface for BotUSD token with reward minting capability
 * @dev Used to mint inflationary rewards that are dripped to stakers
 */
interface IMintableBotUSD is IERC20 {
    /**
     * @notice Mints new BotUSD tokens to specified address
     * @dev Only callable by authorized rewarder address on BotUSD contract
     * @param amount Amount of tokens to mint
     */
    function mintRewards(uint256 amount) external;

    /**
     * @notice Returns total supply of BotUSD
     * @return Total supply in BotUSD base units
     */
    function totalSupply() external view returns (uint256);
}

/**
 * @notice Standard silo interface for reward distribution
 * @dev Implemented by contracts that hold and distribute rewards over time
 */
interface ISilo {
    /**
     * @notice Returns the underlying reward asset
     * @return IMintableBotUSD address of the reward token
     */
    function asset() external view returns (IMintableBotUSD);

    /**
     * @notice Returns the current amount available for withdrawal
     * @dev Amount increases linearly as rewards drip over time
     * @return Available balance that can be withdrawn
     */
    function maxWithdrawable() external view returns (uint256);

    /**
     * @notice Withdraws specified amount to the vault
     * @dev Only callable by authorized vault address
     * @param needed Amount to withdraw
     */
    function withdrawToVault(uint256 needed) external;
}

/**
 * @title RewardSilo
 * @author BotFed Protocol
 * @notice Receives minted BotUSD rewards and drips them linearly to the StakingVault over time
 * @dev UUPS upgradeable contract that acts as a time-release mechanism for staking rewards
 *
 * Key features:
 * - Receives BotUSD minted as inflationary rewards
 * - Releases rewards linearly over DRIP_DURATION_SECONDS (1 week)
 * - Only the StakingVault can withdraw dripped rewards
 * - Owner can mint new reward batches (subject to BotUSD's own limits)
 * - Pausable for emergency situations
 *
 * Flow:
 * 1. Owner calls mintRewards() with amount based on strategy profits
 * 2. BotUSD tokens are minted to this contract
 * 3. Tokens become available linearly over 1 week via maxWithdrawable()
 * 4. StakingVault pulls rewards as needed via withdrawToVault()
 * 5. As StakingVault's totalAssets increases, sBotUSD share value appreciates
 */
contract RewardSilo is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ISilo
{
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ========== */

    /// @notice Duration over which rewards are dripped linearly (1 week)
    uint256 public constant DRIP_DURATION_SECONDS = 7 * 24 * 60 * 60;
    uint256 public constant MAX_PERFORMANCE_FEE_BIPS = 5000; // 50%;

    /* ========== STATE VARIABLES ========== */

    /// @notice BotUSD token contract with minting capability
    IMintableBotUSD public asset;

    /// @notice StakingVault address authorized to withdraw dripped rewards
    address public vault;
    address public feeReceiver;

    /// @notice Amount from previous mints that has dripped but not been withdrawn
    /// @dev Synced at start of each new mint to preserve unredeemed rewards
    uint256 public accumulated;
    uint256 public withdrawn;

    /// @notice Timestamp of the last mintRewards() call
    /// @dev Used to calculate linear drip progress
    uint256 public lastMintTime;
    uint256 public lastUndripped;
    uint256 public performanceFee;

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when new rewards are minted
     * @param amount Amount of BotUSD minted
     * @param timestamp Block timestamp of mint
     */
    event Minted(uint256 amount, uint256 timestamp);

    /**
     * @notice Emitted when rewards are withdrawn to vault
     * @param amount Amount of BotUSD withdrawn
     */
    event Withdrawn(uint256 amount);

    /**
     * @notice Emitted when vault address is updated
     * @param newVault New vault address
     */
    event VaultSet(address indexed oldVault, address indexed newVault);

    event FeeChanged(uint256 oldVal, uint256 newVal);
    event FeeReceiverSet(address indexed oldReceiver, address indexed newReceiver);
    event PerformanceFeePaid(uint256 amount, address indexed receiver);

    /* ========== ERRORS ========== */

    /// @notice Thrown when trying to withdraw more than maxWithdrawable()
    error MaxWithdrawExceeded();

    /// @notice Thrown when caller is not authorized for the function
    error NotAuth();

    /// @notice Thrown when zero address is provided where not allowed
    error ZeroAddress();

    error FeeTooHigh();
    error MintMismatch(uint256 expected, uint256 received);

    /* ========== MODIFIERS ========== */

    /**
     * @notice Restricts function to only the authorized vault
     * @dev Prevents unauthorized withdrawals of dripped rewards
     */
    modifier onlyVault() {
        if (msg.sender != vault) revert NotAuth();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    /**
     * @notice Initializes the RewardSilo contract
     * @dev Can only be called once due to initializer modifier
     * @param asset_ BotUSD token address with minting capability
     * @param initialOwner Address that will own the contract
     * @param vault_ StakingVault address authorized to withdraw rewards
     */
    function initialize(
        IMintableBotUSD asset_,
        address initialOwner,
        address vault_,
        address feeReceiver_,
        uint256 initFee
    ) public initializer {
        if (address(asset_) == address(0)) revert ZeroAddress();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        if (initFee > MAX_PERFORMANCE_FEE_BIPS) revert FeeTooHigh();
        if (initFee > 0 && feeReceiver == address(0)) revert ZeroAddress();

        asset = asset_;
        vault = vault_;
        feeReceiver = feeReceiver_;
        performanceFee = initFee;
        lastMintTime = block.timestamp;

        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Pauses all reward minting and withdrawals
     * @dev Only callable by owner. Used in emergency situations.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses reward minting and withdrawals
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Updates the vault address authorized to withdraw rewards
     * @dev Only callable by owner when paused. Use with extreme caution.
     * @param vault_ New vault address
     */
    function setVault(address vault_) external onlyOwner whenPaused {
        if (vault_ == address(0)) revert ZeroAddress();
        emit VaultSet(vault, vault_);
        vault = vault_;
    }

    function setFeeReceiver(address newReceiver) external onlyOwner whenPaused {
        if (newReceiver == address(0)) revert ZeroAddress();
        emit FeeReceiverSet(feeReceiver, newReceiver);
        feeReceiver = newReceiver;
    }

    function setPerformanceFee(uint256 newVal) external onlyOwner whenPaused {
        if (newVal > MAX_PERFORMANCE_FEE_BIPS) revert FeeTooHigh();
        if (feeReceiver == address(0)) revert ZeroAddress();
        emit FeeChanged(performanceFee, newVal);
        performanceFee = newVal;
    }

    /* ========== REWARD FUNCTIONS ========== */

    /**
     * @notice Mints new BotUSD rewards and starts dripping them over 1 week
     * @dev Only callable by owner when not paused
     *
     * Process:
     * 1. Syncs accumulated to current maxWithdrawable() to preserve undripped rewards
     * 2. Resets drip timer to current timestamp
     * 3. Mints new BotUSD to this contract (subject to BotUSD's own limits)
     * 4. New rewards drip linearly over DRIP_DURATION_SECONDS
     *
     * @param amount Amount of BotUSD to mint and begin dripping
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must be owner
     * - Amount must pass BotUSD contract's minting limits (5% max, 1 week cooldown)
     */

    function mintRewards(uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        if (amount == 0) return;
        // crystallize current drip
        accumulated = maxWithdrawable();
        withdrawn = 0;

        uint256 fee = (amount * performanceFee) / 10_000;

        uint256 balBefore = asset.balanceOf(address(this));
        // Mint first
        asset.mintRewards(amount);
        uint256 received = asset.balanceOf(address(this)) - balBefore;
        if (amount != received) revert MintMismatch(amount, received);

        // Pay fee if configured
        if (fee > 0 && feeReceiver != address(0)) {
            IERC20(asset).safeTransfer(feeReceiver, fee);
            emit PerformanceFeePaid(fee, feeReceiver);
        } else {
            // if no receiver, fee is effectively 0 for this mint
            fee = 0;
        }

        // Set new epoch baseline from actual post-mint, post-fee balance
        lastUndripped = asset.balanceOf(address(this)) - accumulated;
        lastMintTime = block.timestamp;

        emit Minted(amount, block.timestamp);
    }

    function maxWithdrawable() public view returns (uint256) {
        if (paused()) return 0;

        uint256 elapsed = block.timestamp - lastMintTime;
        uint256 newlyDripped;

        if (elapsed >= DRIP_DURATION_SECONDS) {
            // Full drip period has passed, all rewards available
            newlyDripped = lastUndripped;
        } else {
            // Linear interpolation: (amount * time_passed) / total_time
            newlyDripped = (lastUndripped * elapsed) / DRIP_DURATION_SECONDS;
        }
        uint256 bal = asset.balanceOf(address(this));
        uint256 theoretical = accumulated + newlyDripped - withdrawn;

        return theoretical <= bal ? theoretical : bal;
    }

    /**
     * @notice Withdraws dripped rewards to the StakingVault
     * @dev Only callable by authorized vault when not paused
     *
     * Process:
     * 1. Checks amount doesn't exceed maxWithdrawable()
     * 2. Updates accumulated to reflect withdrawal
     * 3. Transfers BotUSD to vault
     *
     * @param amount Amount of BotUSD to withdraw
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must be authorized vault
     * - Amount must be <= maxWithdrawable()
     */
    function withdrawToVault(uint256 amount) external onlyVault nonReentrant whenNotPaused {
        uint256 available = maxWithdrawable();
        if (amount > available) revert MaxWithdrawExceeded();

        // Update accumulated to remaining dripped amount
        withdrawn += amount;

        // Transfer rewards to vault
        IERC20(asset).safeTransfer(vault, amount);
        emit Withdrawn(amount);
    }

    /* ========== UPGRADE AUTHORIZATION ========== */

    /**
     * @notice Authorizes contract upgrades
     * @dev Only callable by owner. Part of UUPS upgrade pattern.
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* ========== STORAGE GAP ========== */

    /**
     * @dev Storage gap for future upgrades
     * Allows adding new state variables without shifting storage layout
     */
    uint256[50] private __gap;
}
