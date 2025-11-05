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

    struct RedemptionRequest {
        uint256 amount; // amount escrowed in the vault
        address receiver; // payout receiver
        address owner; // request owner
        bool fulfilled; // fulfilled
        bool claimed; // claimed
        uint256 assetsLocked;
    }

    address public deprecatedRedeemNFT_OR_newFeatureAddress;

    address public fulfiller;
    address public riskAdmin;
    IStrategyManager public manager;
    address public minter;
    address public rewarder;

    // restrictions on users and tvl
    uint256 public tvlCap;
    bool public userWhiteListActive;
    mapping(address => bool) public userWhiteList;

    mapping(uint256 => RedemptionRequest) public requests;
    uint256 public nextReqId;
    uint256 public amtRequested;

    /* -- Strategy functions --- */
    event ManagerSet(address indexed a);
    event FulfillerSet(address indexed a);
    event RiskAdminSet(address indexed a);
    event MinterSet(address indexed a);
    event RewarderSet(address indexed a);
    event CapitalDeployed(address strat, uint256 amount);
    event RedeemRequestCreated(uint256 indexed id, address indexed owner, address indexed receiver, uint256 shares);
    event RedeemRequestClaimed(
        uint256 indexed id,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assetsOut
    );
    event RedeemRequestFulfilled(
        uint256 indexed id,
        address indexed owner,
        address indexed receiver,
        address fulfiller,
        uint256 requested,
        uint256 assetsLocked
    );
    event RedeemRequestCanceled(uint256 indexed id, address indexed owner, uint256 shares);
    event UserWhiteList(address indexed user, bool isWhiteListed);
    event UserWhiteListActive(bool isActive);
    event TVLCapChanged(uint256 newCap);
    event RewardsMinted(address indexed to, uint256 amount);

    /* ---------- errors ---------- */
    error Disabled();
    error Shortfall(uint256 needed, uint256 got);
    error NotRequestOwner();
    error RequestNotFulfilled();
    error RequestAlreadyClaimed();
    error RequestAlreadyFulfilled();
    error RequestDoesNotExist();

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
        address manager_,
        address fulfiller_,
        address riskAdmin_,
        address minter_,
        address rewarder_
    ) public initializer {
        if (address(asset_) == address(0)) revert(); // asset must be set
        if (initialOwner == address(0)) revert(); // owner must be set
        if (manager_ != address(0)) {
            IStrategyManager m = IStrategyManager(manager_);
            require(m.asset() == asset_, "manager asset mismatch");
            manager = m;
        }

        fulfiller = fulfiller_;
        riskAdmin = riskAdmin_;
        minter = minter_;
        rewarder = rewarder_;
        tvlCap = 32 ether;
        userWhiteListActive = true;

        // Initialize parent contracts
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /*---- setters ---- */

    function setManager(address a) external onlyOwner whenPaused {
        require(a != address(0), "ZM");
        manager = IStrategyManager(a);
        require(address(manager.asset()) == address(asset()), "A");
        emit ManagerSet(a);
    }

    function setMinter(address a) external onlyOwner whenPaused {
        require(a != address(0), "ZA");
        minter = a;
        emit MinterSet(a);
    }

    function setRewarder(address a) external onlyOwner whenPaused {
        require(a != address(0), "ZA");
        rewarder = a;
        emit RewarderSet(a);
    }

    function setFulfiller(address a) external onlyOwner {
        require(a != address(0), "ZF");
        fulfiller = a;
        emit FulfillerSet(a);
    }

    function setRiskAdmin(address a) external onlyOwner {
        require(a != address(0), "ZRA");
        riskAdmin = a;
        emit RiskAdminSet(a);
    }
    function setUserWhiteList(address a, bool isWhiteListed) external onlyRiskAdmin {
        userWhiteList[a] = isWhiteListed;
        emit UserWhiteList(a, isWhiteListed);
    }

    function setUserWhiteListActive(bool b) external onlyRiskAdmin {
        userWhiteListActive = b;
        emit UserWhiteListActive(b);
    }

    function setTVLCap(uint256 newCap) external onlyRiskAdmin {
        tvlCap = newCap;
        emit TVLCapChanged(newCap);
    }

    /* -- some getters */
    function userIsWhitelisted(address a) external view returns (bool) {
        return userWhiteList[a];
    }

    /* ---- modifiers --- */

    // Add a modifier
    modifier onlyMinter() {
        require(msg.sender == minter || msg.sender == owner(), "OM");
        _;
    }

    modifier onlyFulfiller() {
        require(msg.sender == fulfiller || msg.sender == owner(), "OF");
        _;
    }
    modifier onlyRiskAdmin() {
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

    /**
     * @notice Request redemption of shares for underlying assets
     * @param amount Number of shares to redeem
     * @param receiver Address that will receive the redeemed assets (use address(0) for msg.sender)
     * @return id The unique identifier for this redemption request
     * @dev Shares are transferred to vault escrow. Must be fulfilled by fulfiller before claiming.
     */
    function requestRedeem(
        uint256 amount,
        address receiver
    ) external whenNotPaused nonReentrant onlyWhiteListed returns (uint256 id) {
        uint256 maxAmount = maxRedeem(msg.sender);
        if (amount > maxAmount) {
            revert ERC4626ExceededMaxRedeem(msg.sender, amount, maxAmount);
        }
        return _requestRedeem(msg.sender, receiver, amount);
    }

    /**
     * @notice Fulfill a pending redemption request by locking assets
     * @param id The redemption request identifier
     * @dev Only callable by fulfiller. Locks assets at current 1:1 exchange rate.
     *      Pulls liquidity from manager if vault balance insufficient.
     */
    function fulfillRequest(uint256 id) external nonReentrant whenNotPaused onlyFulfiller {
        RedemptionRequest storage r = requests[id];
        if (r.owner == address(0)) revert RequestDoesNotExist();
        if (r.fulfilled) revert RequestAlreadyFulfilled();
        if (r.claimed) revert RequestAlreadyClaimed();

        // ensure liquidity: pull from manager if needed
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        r.assetsLocked = previewRedeem(r.amount);
        amtRequested += r.assetsLocked;
        if (bal < amtRequested) _pullFromManager(amtRequested - bal); // must make funds available or revert
        r.fulfilled = true;
        emit RedeemRequestFulfilled(id, r.owner, r.receiver, msg.sender, r.amount, r.assetsLocked);
    }
    /**
     * @notice Claim assets from a fulfilled redemption request
     * @param id The redemption request identifier
     * @dev Burns escrowed shares and transfers locked assets to receiver.
     *      Only callable by request owner after fulfillment.
     */
    function claimRedemption(uint256 id) external nonReentrant whenNotPaused {
        RedemptionRequest storage r = requests[id];
        if (r.owner != msg.sender) revert NotRequestOwner();
        if (!r.fulfilled) revert RequestNotFulfilled();
        if (r.claimed) revert RequestAlreadyClaimed();
        r.claimed = true;
        delete requests[id];
        _burn(address(this), r.amount);
        IERC20(asset()).safeTransfer(r.receiver, r.assetsLocked);
        amtRequested -= r.assetsLocked;
        emit RedeemRequestClaimed(id, r.owner, r.receiver, r.amount, r.assetsLocked);
    }

    /**
     * @notice Cancel an unfulfilled redemption request
     * @param id The redemption request identifier
     * @dev Returns escrowed shares to owner. Can only cancel before fulfillment.
     */
    function cancelRequest(uint256 id) external nonReentrant whenNotPaused {
        RedemptionRequest storage r = requests[id];
        if (r.owner != msg.sender) revert NotRequestOwner();
        if (r.fulfilled) revert RequestAlreadyFulfilled();
        if (r.claimed) revert RequestAlreadyClaimed();

        uint256 shares = r.amount;
        delete requests[id];

        // Return shares to user
        _transfer(address(this), msg.sender, shares);
        emit RedeemRequestCanceled(id, msg.sender, shares);
    }

    /* view and pure functions */

    function getRequestStatus(
        uint256 id
    ) external view returns (bool exists, bool fulfilled, bool claimed, uint256 shares, uint256 assets) {
        RedemptionRequest storage r = requests[id];
        exists = r.owner != address(0);
        fulfilled = r.fulfilled;
        claimed = r.claimed;
        shares = r.amount;
        assets = r.assetsLocked;
    }
    // 1:1 conversions
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return assets;
    }
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares;
    }

    // Make previews explicit 1:1 (not strictly required, but clearer)
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return assets;
    }
    function previewMint(uint256 shares) public view override returns (uint256) {
        return shares;
    }
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return assets;
    }
    function previewRedeem(uint256 shares) public view override returns (uint256) {
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
    function maxRedeem(address user) public view override returns (uint256) {
        return balanceOf(user);
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

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert Disabled();
    }
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert Disabled();
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
        uint256 b0 = IERC20(asset()).balanceOf(address(this));
        manager.withdrawToVault(needed);
        uint256 got = IERC20(asset()).balanceOf(address(this)) - b0;
        if (got < needed) revert Shortfall(needed, got);
    }

    function _requestRedeem(address owner, address receiver, uint256 amount) internal returns (uint256 id) {
        // 1) escrow in the vault
        _spendAllowance(owner, address(this), amount);
        _transfer(owner, address(this), amount);

        // 2) record request
        id = ++nextReqId;
        requests[id] = RedemptionRequest({
            amount: amount,
            receiver: receiver == address(0) ? owner : receiver,
            owner: owner,
            fulfilled: false,
            claimed: false,
            assetsLocked: 0
        });

        emit RedeemRequestCreated(id, owner, receiver, amount);
    }


    function mintRewards(uint256 shares) external onlyMinter whenNotPaused nonReentrant {
        _mint(rewarder, shares);
        emit RewardsMinted(rewarder, shares);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /* ----------------------------- Storage gap (future-proofing) --------------- */
    uint256[50] private __gap;
}
