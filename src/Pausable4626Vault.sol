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
import {WithdrawRequestNFT} from "./WithdrawRequestNFT.sol";
import {IStrategyManager} from "./StrategyManager.sol";

// Add this interface at the top with other imports
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

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

    address public immutable WETH;

    IStrategyManager public manager;
    WithdrawRequestNFT public withdrawNFT;
    address public fulfiller;

    /* ---------- requests ---------- */
    struct Req {
        uint128 shares; // shares escrowed in the vault
        address receiver; // payout receiver
        address owner; // payout receiver
        bool settled; // fulfilled or canceled
        bool claimed; // fulfilled or canceled
    }
    mapping(uint256 => Req) public requests;
    uint256 public nextReqId;
    uint256 public amtRequested;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _weth) {
        require(_weth != address(0), "WETH address cannot be zero");
        WETH = _weth;
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
        address manager_,
        address fulfiller_
    ) public initializer {
        manager = IStrategyManager(manager_);
        fulfiller = fulfiller_;
        withdrawNFT = new WithdrawRequestNFT("Withdraw Request", "wREQ");

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /* -- Strategy functions --- */
    event ManagerSet(address indexed a);
    event FulfillerSet(address indexed a);
    event CapitalDeployed(address strat, uint256 amount);
    event RequestCreated(
        uint256 indexed id,
        address indexed owner,
        uint256 shares,
        address receiver
    );
    event RequestClaimed(
        uint256 indexed id,
        address indexed owner,
        address receiver,
        uint256 shares
    );
    event RequestFulfilled(
        uint256 indexed id,
        address indexed owner,
        address indexed receiver,
        uint256 assetsOut
    );
    event EmergencyWithdraw(address indexed token, uint256 amount);

    /* ---------- errors ---------- */
    error Disabled();
    error Shortfall(uint256 needed, uint256 got);

    /*---- setters ---- */

    function setManager(address a) external onlyOwner whenPaused {
        require(a != address(0), "ZM");
        manager = IStrategyManager(a);
        require(address(manager.asset()) == address(asset()), "A");
        emit ManagerSet(a);
    }

    function setFulfiller(address a) external onlyOwner {
        require(a != address(0), "ZF");
        fulfiller = a;
        emit FulfillerSet(a);
    }

    /* ---- modifiers --- */

    modifier onlyFulfiller() {
        require(msg.sender == fulfiller, "OF");
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
    ) public override whenNotPaused nonReentrant returns (uint256 shares) {
        require(address(manager) != address(0), "manager not set");
        // 1:1 → shares == assets
        shares = assets;
        // pull assets in
        IERC20(asset()).transferFrom(msg.sender, address(this), assets);
        // mint shares
        _mint(receiver, shares);

        // kick capital to manager
        _pushToManager(assets);
    }

    // 1:1 conversions
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        return assets;
    }
    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256) {
        return shares;
    }

    // Make previews explicit 1:1 (not strictly required, but clearer)
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        return assets;
    }
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        return shares;
    }
    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        return assets;
    }
    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        return shares;
    }

    // CPPS accounting: principal only. If you externalize yield, keep this equal to principal.
    function totalAssets() public view override returns (uint256) {
        // simplest CPPS invariant: principal == totalSupply()
        return totalSupply();
    }

    // disable direct exits
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }
    // Disable share-centric entry
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert Disabled();
    }

    function withdraw(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert Disabled();
    }
    function redeem(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert Disabled();
    }

    function requestWithdrawAssets(
        uint256 assets,
        address receiver
    ) external whenNotPaused returns (uint256 id, uint256 shares) {
        shares = previewWithdraw(assets);
        return _request(shares, receiver);
    }

    function _request(
        uint256 shares,
        address receiver
    ) internal returns (uint256 id, uint256 _shares) {
        _shares = shares;

        // 1) escrow shares in the vault
        _spendAllowance(msg.sender, address(this), _shares);
        _transfer(msg.sender, address(this), _shares);

        // 2) record request
        id = ++nextReqId;
        requests[id] = Req({
            shares: uint128(_shares),
            owner: msg.sender,
            receiver: receiver == address(0) ? msg.sender : receiver,
            settled: false,
            claimed: false
        });

        // 3) mint request NFT to the user
        withdrawNFT.mintTo(msg.sender, id);

        emit RequestCreated(id, msg.sender, _shares, receiver);
    }

    /**
     * @dev Pull exactly `needed` assets from the manager into the vault.
     *      Assumes the manager is configured to let THIS vault call `provideLiquidity`.
     */
    function _pullFromManager(uint256 needed) internal {
        if (needed == 0) return;
        uint256 b0 = IERC20(asset()).balanceOf(address(this));
        manager.withdrawToVault(needed);
        uint256 got = IERC20(asset()).balanceOf(address(this)) - b0;
        if (got < needed) revert Shortfall(needed, got);
    }

    function claimWithdraw(uint256 id) external nonReentrant whenNotPaused {
        Req storage r = requests[id];
        require(r.owner == msg.sender, "CWO");
        require(r.settled, "CWS");
        require(!r.claimed, "CWC");
        uint256 shares = uint256(r.shares);
        r.claimed = true;
        withdrawNFT.burn(id);

        // burn escrowed shares and send assets
        _burn(address(this), shares);
        IERC20(asset()).transfer(r.receiver, shares);
        amtRequested -= shares;
        emit RequestClaimed(id, r.owner, r.receiver, shares);
    }

    // fulfill from a pending request (escrowed shares are held by the vault)
    function fulfillRequest(
        uint256 id
    )
        external
        nonReentrant
        whenNotPaused
        onlyFulfiller
        returns (uint256 assetsOut)
    {
        Req storage r = requests[id];
        require(!r.settled, "settled");

        uint256 shares = uint256(r.shares);
        assetsOut = shares; // 1:1

        // ensure liquidity: pull from manager if needed
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        amtRequested += assetsOut;
        if (bal < amtRequested) {
            _pullFromManager(amtRequested - bal); // must make funds available or revert
        }

        r.settled = true;
        emit RequestFulfilled(id, r.owner, r.receiver, assetsOut);
    }

    /* ---- escape hatch ---- */

    function withdrawToGov(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (token == address(0)) {
            (bool ok, ) = payable(owner()).call{value: amount}("");
            require(ok, "ETH xfer fail");
            emit EmergencyWithdraw(address(0), amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
            emit EmergencyWithdraw(token, amount);
        }
    }

    // Replace the existing receive() function with this:
    receive() external payable {
        // If no ETH sent, do nothing
        if (msg.value == 0) return;

        if (address(asset()) == WETH) {
            require(address(manager) != address(0), "manager not set");
            require(!paused(), "deposits paused");

            // Wrap ETH to WETH
            IWETH(WETH).deposit{value: msg.value}();

            // Mint shares 1:1 with deposited amount
            _mint(msg.sender, msg.value);

            // Push wrapped ETH to manager
            _pushToManager(msg.value);

            // Emit the standard deposit event (you might want to add a specific event)
            emit Deposit(msg.sender, msg.sender, msg.value, msg.value);
        }
        // If asset is not WETH, ETH just stays in contract (emergency withdrawal available)
    }

    /* ----------------------------- UUPS authorization -------------------------- */

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /* ----------------------------- Storage gap (future-proofing) --------------- */
    uint256[50] private __gap;
}
