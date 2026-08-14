// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICommonEvents
/// @author Aurex Protocol
/// @notice Reusable, protocol-wide events shared across contracts.
/// @dev Housed in an interface so contracts can inherit it and emit these events
///      directly. These describe generic administrative actions only; business-domain
///      events will be added alongside their modules in later phases.
interface ICommonEvents {
    /// @notice Emitted when the administrator updates a protocol configuration address.
    /// @param key Short identifier for the configuration slot being changed.
    /// @param previous The address previously stored for `key`.
    /// @param current The new address stored for `key`.
    event ConfigAddressUpdated(bytes32 indexed key, address indexed previous, address indexed current);
}
