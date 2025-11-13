// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* OpenZeppelin Upgradeable */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategy} from "./StrategyBase.sol";

interface IStrategyManager {
    function asset() external view returns (IERC20);
    function withdrawToVault(uint256 amt) external;
    function maxWithdrawable() external view returns (uint256);
}

contract StrategyManager is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_STRATEGIES = 64;
    IERC20 public asset;
    address public vault;
    address public deprecated_treasury; // kept to preserve storage layout from prior version (formerly 'treasury')
    address public exec;

    mapping(address => bool) public isStrategy;
    address[] public strategies;
    mapping(address => uint256) public strategyDeployed;
    mapping(address => uint256) public strategyWithdrawn;

    bool internal _paused;

    event StrategyAdded(address indexed strat);
    event StrategyRemoved(address indexed strat);
    event CapitalPushed(address indexed strat, uint256 amount);
    event CapitalPulled(address indexed strat, uint256 requested, uint256 received);
    event WithdrawnTo(address indexed to, uint256 amount);
    event SetVault(address indexed oldVault, address indexed newVault);
    event SetExec(address indexed oldExec, address indexed newExec);

    event Paused(address account);
    event Unpaused(address account);

    error UnknownStrategy();
    error InconsistentReturn();
    error ZeroAmount();
    error InsufficientAssets(uint256 requested, uint256 available);
    error OnlyVault();
    error OnlyExecOrOwner();
    error ZeroAddress();
    error MaxStrategies();
    error StrategyAlreadyExists();
    error StrategyDoesNotExist();
    error StrategyInvalidOwner();
    error StrategyInvalidAsset();

    /* Modifiers */

    modifier whenNotPaused() {
        require(!paused(), "Paused");
        _;
    }

    modifier whenPaused() {
        require(paused(), "Not paused");
        _;
    }

    modifier onlyVault() {
        _onlyVault();
        _;
    }
    function _onlyVault() internal {
        if (msg.sender != vault) revert OnlyVault();
    }

    modifier onlyExecOrOwner() {
        _onlyExecOrOwner();
        _;
    }

    function _onlyExecOrOwner() internal {
        if (msg.sender != exec && msg.sender != owner()) revert OnlyExecOrOwner();
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 asset_, address owner_, address exec_) public initializer {
        if (address(asset_) == address(0) || owner_ == address(0)) revert ZeroAddress();

        asset = asset_;
        exec = exec_;

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /* ------------------------ Admin functions ------------------------ */
    function pause() external onlyOwner whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    function setVault(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address oldVault = vault;
        vault = a;
        emit SetVault(oldVault, a);
    }

    function setExec(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address old = exec;
        exec = a;
        emit SetExec(old, a);
    }

    /// @notice Registers a new strategy. Must share same asset and owner.
    ///         Does not verify implementation beyond basic interface.
    function addStrategy(address strat) external onlyOwner {
        if (strat == address(0)) revert ZeroAddress();
        if (isStrategy[strat]) revert StrategyAlreadyExists();
        if (strategies.length >= MAX_STRATEGIES) revert MaxStrategies();
        if (OwnableUpgradeable(strat).owner() != owner()) revert StrategyInvalidOwner();
        if (IStrategy(strat).asset() != asset) revert StrategyInvalidAsset();

        isStrategy[strat] = true;
        strategies.push(strat);
        emit StrategyAdded(strat);
    }

    function removeStrategy(address strat) external onlyOwner {
        if (strat == address(0)) revert ZeroAddress();
        if (!isStrategy[strat]) revert StrategyDoesNotExist();

        // Find the strategy in the array
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == strat) {
                // Move last element to this position
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }

        isStrategy[strat] = false;
        emit StrategyRemoved(strat);
    }

    /* ---------------------- Capital movement --------------------- */

    function pushToStrategy(address strat, uint256 amount) external nonReentrant onlyExecOrOwner whenNotPaused {
        if (!isStrategy[strat]) revert UnknownStrategy();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = asset.balanceOf(address(this));
        if (amount > bal) revert InsufficientAssets(amount, bal);
        asset.safeTransfer(strat, amount);
        strategyDeployed[strat] += amount;
        emit CapitalPushed(strat, amount);
    }

    /// @dev Removed strategies cannot be pulled. Re-add the strategy to reclaim funds.
    function pullFromStrategy(
        address strat,
        uint256 requested
    ) public nonReentrant onlyExecOrOwner whenNotPaused returns (uint256 received) {
        if (!isStrategy[strat]) revert UnknownStrategy();
        uint256 balanceBefore = asset.balanceOf(address(this));
        received = IStrategy(strat).withdrawToManager(requested);
        uint256 actualReceived = asset.balanceOf(address(this)) - balanceBefore;
        strategyWithdrawn[strat] += actualReceived;
        if (actualReceived < received) revert InconsistentReturn();
        emit CapitalPulled(strat, requested, actualReceived);
    }

    /// @notice Sends `amount` of idle `asset` to the vault.
    ///         Does NOT currently pull from strategies. Off-chain orchestration should pre-fund this.
    function withdrawToVault(uint256 amount) external onlyVault nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        uint256 b0 = maxWithdrawable();
        if (b0 < amount) revert InsufficientAssets(amount, b0);
        asset.safeTransfer(vault, amount);
        emit WithdrawnTo(vault, amount);
    }

    /* Views */

    /// @notice Returns max amount withdrawable by vault. Currently just returns idle balance as we are not pulling from strats atomically.
    function maxWithdrawable() public view returns (uint256) {
        if (paused()) return 0;
        return asset.balanceOf(address(this));
    }
    function paused() public view returns (bool) {
        return _paused;
    }

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }
    /* ---------------------- UUPS authorization --------------------- */
    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}

    /* -------------------------- Receive guard ---------------------- */
    receive() external payable {
        revert("no direct ETH");
    }

    /* ========== STORAGE GAP ========== */

    /**
     * @dev Storage gap for future upgrades
     * Original: 45 slots
     * Used: 1 slots for _paused (Nov 13 2025)
     * Remaining: 44 slots
     */
    uint256[44] private __gap;
}
