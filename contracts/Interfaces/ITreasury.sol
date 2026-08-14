// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ITreasury
/// @author Aurex Protocol
/// @notice Events and integration surface for the protocol {Treasury} vault.
/// @dev The Treasury is a pure vault: it custodies ERC-20 tokens and native BNB and moves
///      funds out only when instructed by an authorized protocol contract, or by the owner
///      during an emergency. It performs no reward, ROI, MLM or referral accounting. In any
///      event that describes native BNB, the `token` field is the zero address.
///
///      This interface intentionally exposes only the read surface and the protocol-facing
///      (authorized-contract) functions. Owner-only administration — token configuration,
///      authorization management and emergency withdrawals — lives on the concrete contract.
interface ITreasury {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted once when the USDT token address is configured.
    /// @param usdt The configured USDT token address.
    event USDTConfigured(address indexed usdt);

    /// @notice Emitted once when the ARX token address is configured.
    /// @param arx The configured ARX token address.
    event ARXConfigured(address indexed arx);

    /// @notice Emitted when a contract is granted authorization to move protocol funds.
    /// @param account The newly authorized address.
    event ContractAuthorized(address indexed account);

    /// @notice Emitted when a contract's authorization is revoked.
    /// @param account The address whose authorization was removed.
    event ContractRemoved(address indexed account);

    /// @notice Emitted when funds are deposited into the treasury.
    /// @param token The deposited token address, or the zero address for native BNB.
    /// @param from The depositor.
    /// @param amount The amount deposited.
    event DepositReceived(address indexed token, address indexed from, uint256 amount);

    /// @notice Emitted when an authorized contract moves funds out of the treasury.
    /// @param token The transferred token address.
    /// @param to The recipient.
    /// @param amount The amount transferred.
    event TransferExecuted(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the owner performs an emergency withdrawal.
    /// @param token The withdrawn token address, or the zero address for native BNB.
    /// @param to The recipient.
    /// @param amount The amount withdrawn.
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Configuration views
    // -------------------------------------------------------------------------

    /// @notice The configured USDT token address (zero if not yet configured).
    function usdt() external view returns (address);

    /// @notice The configured ARX token address (zero if not yet configured).
    function arx() external view returns (address);

    /// @notice Whether `account` is authorized to move protocol funds.
    function authorizedContracts(address account) external view returns (bool);

    // -------------------------------------------------------------------------
    // Balance views
    // -------------------------------------------------------------------------

    /// @notice Returns the treasury's balance of `token`.
    function balanceOfToken(address token) external view returns (uint256);

    /// @notice Returns the treasury's native BNB balance.
    function balanceBNB() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Protocol operations (authorized contracts only)
    // -------------------------------------------------------------------------

    /// @notice Pulls `amount` of `token` from the caller into the treasury.
    function depositToken(address token, uint256 amount) external;

    /// @notice Deposits the attached native BNB into the treasury.
    function depositBNB() external payable;

    /// @notice Transfers `amount` of the configured USDT to `to`.
    function transferUSDT(address to, uint256 amount) external;

    /// @notice Transfers `amount` of the configured ARX to `to`.
    function transferARX(address to, uint256 amount) external;

    /// @notice Transfers `amount` of an arbitrary `token` to `to`.
    function transferToken(address token, address to, uint256 amount) external;
}
