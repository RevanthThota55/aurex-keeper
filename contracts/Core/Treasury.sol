// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ZeroAddress, ZeroAmount} from "../Errors/CommonErrors.sol";
import {
    InsufficientTreasuryBalance,
    InvalidToken,
    TokenAlreadyConfigured,
    TransferFailed,
    UnauthorizedContract
} from "../Errors/TreasuryErrors.sol";
import {ITreasury} from "../Interfaces/ITreasury.sol";

/// @title Treasury
/// @author Aurex Protocol
/// @notice Secure, upgradeable custody vault for the Aurex protocol.
/// @dev
/// ## Purpose
/// The Treasury is the protocol "bank". It securely holds ERC-20 tokens (notably USDT and
/// ARX) and native BNB, and moves funds out **only** when instructed by an authorized
/// protocol contract, or by the owner during an emergency. It performs **no** reward, ROI,
/// MLM, referral, package or liquidity accounting — that logic lives in other modules that
/// call into this vault.
///
/// ## Security model
/// - `Ownable`: the owner configures token addresses, manages the authorization set and can
///   perform emergency withdrawals.
/// - Authorization: only addresses in {authorizedContracts} may deposit or move protocol
///   funds. Random contracts cannot touch the vault.
/// - `SafeERC20` is used for every ERC-20 interaction; `nonReentrant` guards every
///   fund-moving function; every operation validates zero address, zero amount and
///   sufficient balance.
///
/// ## Reentrancy guard
/// OpenZeppelin v5 consolidated `ReentrancyGuardUpgradeable` into the storage-namespaced,
/// upgrade-safe `ReentrancyGuard` (ERC-7201, storage-stateless); it needs no initializer
/// and is safe behind a proxy. This is the current equivalent of the guard requested for
/// this phase.
///
/// ## Upgradeability
/// UUPS (ERC-1967). Deploy behind an `ERC1967Proxy`; state lives in the proxy. The
/// constructor locks the implementation with `_disableInitializers()`, and only the owner
/// may authorize an upgrade.
contract Treasury is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable, ITreasury {
    using SafeERC20 for IERC20;

    /// @notice Sentinel used in events to denote native BNB (which has no token address).
    address private constant NATIVE = address(0);

    /// @notice The configured USDT token address. Write-once.
    address public override usdt;

    /// @notice The configured ARX token address. Write-once.
    address public override arx;

    /// @notice Whether an address is authorized to move protocol funds.
    mapping(address account => bool authorized) public override authorizedContracts;

    /// @notice Reserved storage slots so future upgrades can add state without shifting the
    ///         layout of the variables declared above (3 used + 47 reserved = 50).
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[47] private __gap;

    /// @notice Restricts a function to addresses in the {authorizedContracts} set.
    modifier onlyAuthorized() {
        if (!authorizedContracts[msg.sender]) revert UnauthorizedContract();
        _;
    }

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Treasury and assigns ownership.
    /// @dev Callable exactly once, on the proxy. The reentrancy guard requires no
    ///      initialization (it is storage-stateless in OpenZeppelin v5).
    /// @param owner_ Protocol administrator; receives ownership and upgrade rights.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
    }

    // -------------------------------------------------------------------------
    // Owner: token configuration (write-once)
    // -------------------------------------------------------------------------

    /// @notice Configures the USDT token address. Callable once by the owner.
    /// @param usdt_ The USDT token address (non-zero).
    function setUSDT(address usdt_) external onlyOwner {
        if (usdt_ == address(0)) revert InvalidToken();
        if (usdt != address(0)) revert TokenAlreadyConfigured();
        usdt = usdt_;
        emit USDTConfigured(usdt_);
    }

    /// @notice Configures the ARX token address. Callable once by the owner.
    /// @param arx_ The ARX token address (non-zero).
    function setARX(address arx_) external onlyOwner {
        if (arx_ == address(0)) revert InvalidToken();
        if (arx != address(0)) revert TokenAlreadyConfigured();
        arx = arx_;
        emit ARXConfigured(arx_);
    }

    // -------------------------------------------------------------------------
    // Owner: authorization management
    // -------------------------------------------------------------------------

    /// @notice Grants `account` authorization to move protocol funds.
    /// @param account The address to authorize (non-zero).
    function authorizeContract(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedContracts[account] = true;
        emit ContractAuthorized(account);
    }

    /// @notice Revokes `account`'s authorization to move protocol funds.
    /// @param account The address to de-authorize (non-zero).
    function removeAuthorizedContract(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedContracts[account] = false;
        emit ContractRemoved(account);
    }

    // -------------------------------------------------------------------------
    // Protocol: deposits (authorized contracts only)
    // -------------------------------------------------------------------------

    /// @notice Pulls `amount` of `token` from the caller into the treasury.
    /// @dev The caller must have approved the treasury for at least `amount`.
    /// @param token The ERC-20 token to deposit (non-zero).
    /// @param amount The amount to deposit (non-zero).
    function depositToken(address token, uint256 amount) external override onlyAuthorized nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit DepositReceived(token, msg.sender, amount);
    }

    /// @notice Deposits the attached native BNB into the treasury.
    /// @dev The amount is `msg.value`, which must be non-zero.
    function depositBNB() external payable override onlyAuthorized nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        emit DepositReceived(NATIVE, msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------
    // Protocol: transfers out (authorized contracts only)
    // -------------------------------------------------------------------------

    /// @notice Transfers `amount` of the configured USDT to `to`.
    /// @param to The recipient (non-zero).
    /// @param amount The amount to transfer (non-zero).
    function transferUSDT(address to, uint256 amount) external override onlyAuthorized nonReentrant {
        _transferToken(usdt, to, amount);
    }

    /// @notice Transfers `amount` of the configured ARX to `to`.
    /// @param to The recipient (non-zero).
    /// @param amount The amount to transfer (non-zero).
    function transferARX(address to, uint256 amount) external override onlyAuthorized nonReentrant {
        _transferToken(arx, to, amount);
    }

    /// @notice Transfers `amount` of an arbitrary `token` to `to`.
    /// @param token The ERC-20 token to transfer (non-zero).
    /// @param to The recipient (non-zero).
    /// @param amount The amount to transfer (non-zero).
    function transferToken(address token, address to, uint256 amount) external override onlyAuthorized nonReentrant {
        _transferToken(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // Owner: emergency withdrawals
    // -------------------------------------------------------------------------

    /// @notice Emergency-withdraws `amount` of `token` to `to`. Owner only.
    /// @param token The ERC-20 token to withdraw (non-zero).
    /// @param to The recipient (non-zero).
    /// @param amount The amount to withdraw (non-zero, <= treasury balance).
    function emergencyWithdrawToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientTreasuryBalance();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdrawal(token, to, amount);
    }

    /// @notice Emergency-withdraws `amount` of native BNB to `to`. Owner only.
    /// @param to The recipient (non-zero).
    /// @param amount The amount to withdraw (non-zero, <= treasury balance).
    function emergencyWithdrawBNB(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientTreasuryBalance();
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit EmergencyWithdrawal(NATIVE, to, amount);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns the treasury's balance of `token`.
    /// @param token The ERC-20 token to query (non-zero).
    function balanceOfToken(address token) external view override returns (uint256) {
        if (token == address(0)) revert InvalidToken();
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns the treasury's native BNB balance.
    function balanceBNB() external view override returns (uint256) {
        return address(this).balance;
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Shared, validated ERC-20 transfer-out used by the protocol transfer functions.
    /// @param token The token to transfer (non-zero).
    /// @param to The recipient (non-zero).
    /// @param amount The amount (non-zero, <= treasury balance).
    function _transferToken(address token, address to, uint256 amount) private {
        if (token == address(0)) revert InvalidToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientTreasuryBalance();
        IERC20(token).safeTransfer(to, amount);
        emit TransferExecuted(token, to, amount);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. Parameter name omitted to avoid a warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
