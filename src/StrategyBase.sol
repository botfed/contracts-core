// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/* ---- Strategy interface expected by the manager ---- */
interface IStrategy {
    function withdrawToManager(
        uint256 assets
    ) external returns (uint256 withdrawn);
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

    IERC20 public assetToken; // e.g., WETH
    address public manager; // StrategyVaultManager
    address public executor; // keeper/bot
    address public riskAdmin; // keeper/bot

    event ManagerSet(address indexed manager);
    event RiskAdminSet(address indexed riskAdmin);
    event ExecutorSet(address indexed executor);
    event Withdrawn(address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed token, uint256 amount);

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
    ) public initializer {
        require(owner_ != address(0), "owner=0");
        require(manager_ != address(0), "manager=0");
        require(riskAdmin_ != address(0), "riskAdmin=0");
        require(executor_ != address(0), "executor=0");
        require(address(asset_) != address(0), "asset=0");

        manager = manager_;
        executor = executor_;
        riskAdmin = riskAdmin_;
        assetToken = asset_;

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        emit RiskAdminSet(riskAdmin);
        emit ManagerSet(manager_);
        emit ExecutorSet(executor_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /* -------------------- admin setters --------------------- */
    modifier onlyExecutorOrGov() {
        require(msg.sender == executor || msg.sender == owner(), "not auth");
        _;
    }

    modifier onlyManagerOrGov() {
        require(msg.sender == manager || msg.sender == owner(), "not auth");
        _;
    }

    modifier onlyRiskAdminOrGov() {
        require(msg.sender == riskAdmin || msg.sender == owner(), "not auth");
        _;
    }

    function setExecutor(address a) external onlyExecutorOrGov {
        require(a != address(0), "executor=0");
        executor = a;
        emit ExecutorSet(a);
    }

    function setRiskAdmin(address a) external onlyRiskAdminOrGov {
        require(a != address(0), "riskAdmin=0");
        riskAdmin = a;
        emit RiskAdminSet(a);
    }

    function setManager(address a) external onlyOwner {
        require(a != address(0), "manager=0");
        manager = a;
        emit ManagerSet(a);
    }

    /* -------------------- manager withdrawals -------------------- */
    /// @notice Manager pulls `assets` of the strategy's asset to `recipient`.
    function withdrawToManager(
        uint256 assets
    ) external onlyManagerOrGov nonReentrant returns (uint256 withdrawn) {
        uint256 bal = assetToken.balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        if (withdrawn > 0) assetToken.safeTransfer(manager, withdrawn);
        emit Withdrawn(manager, withdrawn);
    }

    // manual escape hatch to manager that can be called by exectuor

    function withdrawToManager(
        address token,
        uint256 amount
    ) external onlyExecutorOrGov nonReentrant {
        if (token == address(0)) {
            (bool ok, ) = payable(manager).call{value: amount}("");
            require(ok, "ETH xfer fail");
            emit EmergencyWithdraw(address(0), amount);
        } else {
            IERC20(token).safeTransfer(manager, amount);
            emit EmergencyWithdraw(token, amount);
        }
    }

    receive() external payable {}
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    uint256[48] private __gap;
}
