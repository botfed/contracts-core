// SPDX-License-Identifier: Prop
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/* ---- Strategy interface expected by the manager ---- */
interface IStrategy {
    function withdrawToManager(uint256 assets) external returns (uint256 withdrawn);
    function asset() external view returns (IERC20);
}

/* ------------ Base strategy (upgradeable) ------------ */
abstract contract StrategyBaseUpgradeable is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IStrategy
{
    using SafeERC20 for IERC20;

    IERC20 public asset; // e.g., WETH
    address public manager; // StrategyManager
    address public executor; // keeper/bot
    address public riskAdmin; // keeper/bot

    event ManagerSet(address indexed oldManager, address indexed newManager);
    event RiskAdminSet(address indexed oldRiskAdmin, address indexed newRiskAdmin);
    event ExecutorSet(address indexed oldExec, address indexed newExec);
    event Withdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error NotAuth();

    /* -------------------- init / upgrade -------------------- */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address manager_,
        address riskAdmin_,
        address executor_,
        IERC20 asset_
    ) public virtual initializer {
        if (
            owner_ == address(0) ||
            manager_ == address(0) ||
            riskAdmin_ == address(0) ||
            executor_ == address(0) ||
            address(asset_) == address(0)
        ) revert ZeroAddress();

        manager = manager_;
        executor = executor_;
        riskAdmin = riskAdmin_;
        asset = asset_;

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        emit RiskAdminSet(address(0), riskAdmin);
        emit ManagerSet(address(0), manager);
        emit ExecutorSet(address(0), executor);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* -------------------- admin setters --------------------- */
    modifier onlyExecutorOrGov() {
        if (msg.sender != executor && msg.sender != owner()) revert NotAuth();
        _;
    }

    modifier onlyManagerOrGov() {
        if (msg.sender != manager && msg.sender != owner()) revert NotAuth();
        _;
    }

    modifier onlyRiskAdminOrGov() {
        if (msg.sender != riskAdmin && msg.sender != owner()) revert NotAuth();
        _;
    }

    function setExecutor(address a) external onlyExecutorOrGov {
        if (a == address(0)) revert ZeroAddress();
        address old = executor;
        executor = a;
        emit ExecutorSet(old, a);
    }

    function setRiskAdmin(address a) external onlyRiskAdminOrGov {
        if (a == address(0)) revert ZeroAddress();
        address old = riskAdmin;
        riskAdmin = a;
        emit RiskAdminSet(old, a);
    }

    function setManager(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        address old = manager;
        manager = a;
        emit ManagerSet(old, a);
    }

    /// @notice Transfers up to `assets` of the strategy asset to the manager.
    /// @return withdrawn The amount actually transferred (<= requested and <= balance).
    /// @dev Manager-initiated pull; strategy never pushes proactively.
    function withdrawToManager(uint256 assets) external onlyManagerOrGov nonReentrant returns (uint256 withdrawn) {
        uint256 bal = asset.balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        if (withdrawn > 0) asset.safeTransfer(manager, withdrawn);
        emit Withdrawn(manager, withdrawn);
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    uint256[48] private __gap;
}
