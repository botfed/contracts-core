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
}

contract StrategyManager is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /* ------------------------- Config ------------------------- */
    uint256 public constant MAX_STRATEGIES = 64; // pick a sane cap
    IERC20 public asset; // e.g., WETH
    address public vault; // the only address allowed to request funds out (user exits)
    address public treasury; // DAO treasury for fees / emergencies
    address public exec; // Exec agent for moving money around in gated way

    /* ---------------------- Strategy Set ---------------------- */
    mapping(address => bool) public isStrategy;
    address[] public strategies; // may contain disabled entries; check isStrategy[strat]
    mapping(address => uint256) public strategyDeployed;
    mapping(address => uint256) public strategyWithdrawn;

    /* ------------------------- Events ------------------------- */
    event StrategyAdded(address indexed strat);
    event StrategyRemoved(address indexed strat);
    event CapitalPushed(address indexed strat, uint256 amount);
    event CapitalPulled(
        address indexed strat,
        uint256 requested,
        uint256 received
    );
    event WithdrawnTo(address indexed to, uint256 amount);
    event SetVault(address indexed who);
    event SetTreasury(address indexed who);
    event SetExec(address indexed who);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    /* ------------------------- Errors ------------------------- */
    error UnknownStrategy();
    error InconsistentReturn();
    error Shortfall(uint256 requested, uint256 available);
    error ZeroAmount();
    error InsufficientAssets(uint256 requested, uint256 available);

    modifier onlyExec() {
        require(msg.sender == exec || msg.sender == owner(), "OE");
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault || msg.sender == owner(), "OE");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 asset_,
        address owner_,
        address treasury_,
        address exec_
    ) public initializer {
        require(address(asset_) != address(0), "asset=0");
        require(owner_ != address(0), "owner=0");
        require(treasury_ != address(0), "treasury=0");

        asset = asset_;
        treasury = treasury_;
        exec = exec_;

        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /* ------------------------ Admin set ------------------------ */

    function setVault(address a) external onlyOwner {
        require(a != address(0), "withdraw=0");
        vault = a;
        emit SetVault(a);
    }

    function setTreasury(address a) external onlyOwner {
        require(a != address(0), "treasury=0");
        treasury = a;
        emit SetTreasury(a);
    }

    function setExec(address a) external onlyOwner {
        require(a != address(0), "exec=0");
        exec = a;
        emit SetExec(a);
    }

    /* -------------------- Strategy management -------------------- */

    function addStrategy(address strat) external onlyOwner {
        require(strat != address(0), "strat=0");
        require(!isStrategy[strat], "exists");
        require(strategies.length < MAX_STRATEGIES, "max strategies");

        // Optional: Validate interface
        try IStrategy(strat).withdrawToManager(0) returns (uint256) {
            // Interface check passed
        } catch {
            revert("Invalid strategy interface");
        }

        isStrategy[strat] = true;
        strategies.push(strat);
        emit StrategyAdded(strat);
    }

    function removeStrategy(address strat) external onlyOwner {
        require(isStrategy[strat], "missing");

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

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    /* ---------------------- Capital movement --------------------- */

    /// @notice Push `amount` of `asset` to a strategy.
    function pushToStrategy(
        address strat,
        uint256 amount
    ) external nonReentrant onlyExec {
        if (!isStrategy[strat]) revert UnknownStrategy();
        if (amount == 0) revert ZeroAmount();
        asset.safeTransfer(strat, amount);
        strategyDeployed[strat] += amount;
        emit CapitalPushed(strat, amount);
    }

    /// @notice Pull `amount` of `asset` back from a specific strategy to this manager.
    function pullFromStrategy(
        address strat,
        uint256 requested
    ) public nonReentrant onlyExec returns (uint256 received) {
        if (!isStrategy[strat]) revert UnknownStrategy();
        uint256 balanceBefore = asset.balanceOf(address(this));
        received = IStrategy(strat).withdrawToManager(requested);
        uint256 actualReceived = asset.balanceOf(address(this)) - balanceBefore;
        strategyWithdrawn[strat] += actualReceived;
        if (actualReceived < received) revert InconsistentReturn();
        emit CapitalPulled(strat, requested, actualReceived);
    }

    /// @notice Satisfy a withdrawal request by sending `amount` to `to`,
    ///         pulling from strategies as needed. Callable by Withdraw Vault.
    function withdrawToVault(uint256 amount) external onlyVault nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 b0 = asset.balanceOf(address(this));
        if (b0 < amount) revert InsufficientAssets(amount, b0);
        asset.safeTransfer(vault, amount);
        emit WithdrawnTo(vault, amount);
    }

    /* --------------------------- Admin ops -------------------------- */

    /* -------------------- emergencies (owner/executor) -------------------- */
    function forceSweepToTreasury(
        address token,
        uint256 amount
    ) external onlyExec nonReentrant {
        if (token == address(0)) {
            (bool ok, ) = payable(treasury).call{value: amount}("");
            require(ok, "ETH xfer fail");
            emit EmergencyWithdraw(address(0), amount);
        } else {
            IERC20(token).safeTransfer(treasury, amount);
            emit EmergencyWithdraw(token, amount);
        }
    }

    /* --- Other convencience views --- */
    function strategyNetDeployed(address strat) external view returns (int256) {
        return
            int256(strategyDeployed[strat]) - int256(strategyWithdrawn[strat]);
    }
    function getStrategyDeployed(
        address strat
    ) external view returns (uint256) {
        return strategyDeployed[strat];
    }
    function getStrategyWithdrawn(
        address strat
    ) external view returns (uint256) {
        return strategyWithdrawn[strat];
    }

    function getActiveStrategies() external view returns (address[] memory) {
        address[] memory active = new address[](strategies.length);
        uint256 count = 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (isStrategy[strategies[i]]) {
                active[count] = strategies[i];
                count++;
            }
        }

        // Resize array to actual count
        assembly {
            mstore(active, count)
        }
        return active;
    }

    function getTotalDeployed() external view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (isStrategy[strategies[i]]) {
                total += strategyDeployed[strategies[i]];
            }
        }
    }

    function getTotalWithdrawn() external view returns (uint256 total) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (isStrategy[strategies[i]]) {
                total += strategyWithdrawn[strategies[i]];
            }
        }
    }

    /* ---------------------- UUPS authorization --------------------- */
    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}

    /* -------------------------- Receive guard ---------------------- */
    receive() external payable {
        revert("no direct ETH");
    }

    uint256[45] private __gap;
}
