// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IWhitelistable {
    function whitelistFromReferrer(address user) external;
}

contract ReferralCodes is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    uint256 public constant DEFAULT_CLAIMS_PER_CODE = 5;
    address public botUSD;
    address public codeGenerator;

    mapping(bytes32 => uint256) public referralCodes;
    mapping(address => bytes32) public referredBy;
    mapping(bytes32 => address) public codeOwners;

    uint256 public numCodes;
    uint256 public numTotalClaimable;
    uint256 public numClaimed;

    event CodeCreated(bytes32 indexed code, address indexed owner, uint256 claims);
    event CodeClaimed(bytes32 indexed code, address indexed user);
    event BotUSDSet(address indexed oldBotUSD, address indexed newBotUSD);
    event CodeGeneratorSet(address indexed oldGen, address indexed newGen);

    error NotAuth;
    error ZeroAddress;
    error AlreadyReferred;
    error InvalidCode;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    function initialize(address initialOwner, address botUSD_, address codeGen_) external initializer {
        if (initialOwner == address(0) || botUSD_ == address(0) || codeGen_ == address(0)) revert ZeroAddress();

        botUSD = botUSD_;
        codeGenerator = codeGen_;

        bytes32 genesisCode = 0xf4930ec5e520399e8f570687e197c3d3c51ad5d7f852a40e8c776a48b211f9f1;
        referralCodes[genesisCode] = 100;
        codeOwners[genesisCode] = address(0);
        numCodes = 1;
        numTotalClaimable = 100;

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        emit CodeCreated(genesisCode, address(0), 100);
        emit CodeGeneratorSet(address(0), codeGenerator);
        emit BotUSDSet(address(0), botUser);
    }

    modifier onlyGenerator() {
        if (msg.sender != codeGenerator) revert NotAuth();
        _;
    }

    /**
     * @notice Updates the BotUSD vault address
     * @dev Only callable by owner
     */
    function setBotUSD(address botUSD_) external onlyOwner {
        if (botUSD_ == address(0)) revert ZeroAddress();
        address old = botUSD;
        botUSD = botUSD_;
        emit BotUSDSet(old, botUSD_);
    }

    /**
     * @notice Updates the code generator address
     * @dev Only callable by owner
     */
    function setCodeGenerator(address codeGen_) external onlyOwner {
        if (codeGen_ == address(0)) revert ZeroAddress();
        address old = codeGenerator;
        codeGenerator = codeGen_;
        emit CodeGeneratorSet(old, codeGen_);
    }

    function createCode(bytes32 code, address owner_) external onlyGenerator {
        if (referralCodes[code] != 0) return;
        referralCodes[code] = DEFAULT_CLAIMS_PER_CODE;
        codeOwners[code] = owner_;
        numCodes += 1;
        numTotalClaimable += DEFAULT_CLAIMS_PER_CODE;
        emit CodeCreated(code, owner_, DEFAULT_CLAIMS_PER_CODE);
    }

    function claimCode(string calldata codeString) external {
        if (referredBy[msg.sender] != bytes32(0)) revert AlreadyReferred();
        bytes32 code = keccak256(abi.encodePacked(codeString));
        if (referralCodes[code] == 0) revert InvalidCode();
        referredBy[msg.sender] = code;
        referralCodes[code] -= 1;
        numClaimed += 1;
        _whitelistUser(msg.sender);
        emit CodeClaimed(code, msg.sender);
    }

    function _whitelistUser(address user) internal {
        IWhitelistable(botUSD).whitelistFromReferrer(user);
    }

    /**
     * @notice Authorizes contract upgrades
     * @dev Only callable by owner. Part of UUPS upgrade pattern.
     *
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    uint256[50] private __gap;
}
