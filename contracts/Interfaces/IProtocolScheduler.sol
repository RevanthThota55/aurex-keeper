// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProtocolScheduler
/// @author Aurex Protocol
/// @notice Events and integration surface for the {ProtocolScheduler} — the protocol's single
///         timing source and duplicate-execution guard.
/// @dev Consumers (notably the ProtocolEngine, in a later phase) read the protocol day/week/
///      month and check/mark per-user processing through this interface.
interface IProtocolScheduler {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the scheduler is paused.
    event SchedulerPaused();

    /// @notice Emitted when the scheduler is resumed.
    event SchedulerResumed();

    /// @notice Emitted when a user's daily processing is marked for `day`.
    event DailyMarked(address indexed user, uint256 day);

    /// @notice Emitted when a user's weekly processing is marked for `week`.
    event WeeklyMarked(address indexed user, uint256 week);

    /// @notice Emitted when a user's monthly processing is marked for `month`.
    event MonthlyMarked(address indexed user, uint256 month);

    // -------------------------------------------------------------------------
    // Timing views
    // -------------------------------------------------------------------------

    /// @notice The current protocol day (1 on the launch day).
    function currentDay() external view returns (uint256);

    /// @notice The current protocol week (1 in the launch week).
    function currentWeek() external view returns (uint256);

    /// @notice The current protocol month (1 in the launch month).
    function currentMonth() external view returns (uint256);

    /// @notice Full days elapsed since launch (0 on the launch day).
    function daysSinceLaunch() external view returns (uint256);

    /// @notice Full weeks elapsed since launch (0 in the launch week).
    function weeksSinceLaunch() external view returns (uint256);

    /// @notice Full months elapsed since launch (0 in the launch month).
    function monthsSinceLaunch() external view returns (uint256);

    // -------------------------------------------------------------------------
    // Execution guards
    // -------------------------------------------------------------------------

    /// @notice Whether `user` may be processed for the current day.
    function canProcessDaily(address user) external view returns (bool);

    /// @notice Whether `user` may be processed for the current week.
    function canProcessWeekly(address user) external view returns (bool);

    /// @notice Whether `user` may be processed for the current month.
    function canProcessMonthly(address user) external view returns (bool);

    /// @notice Marks `user` as processed for the current day.
    function markDailyProcessed(address user) external;

    /// @notice Marks `user` as processed for the current week.
    function markWeeklyProcessed(address user) external;

    /// @notice Marks `user` as processed for the current month.
    function markMonthlyProcessed(address user) external;

    // -------------------------------------------------------------------------
    // State getters
    // -------------------------------------------------------------------------

    /// @notice The timestamp at which the protocol launched (scheduler initialization).
    function protocolLaunchTimestamp() external view returns (uint256);

    /// @notice The protocol day recorded at the most recent daily execution.
    function currentProtocolDay() external view returns (uint256);

    /// @notice The protocol week recorded at the most recent weekly execution.
    function currentProtocolWeek() external view returns (uint256);

    /// @notice The protocol month recorded at the most recent monthly execution.
    function currentProtocolMonth() external view returns (uint256);

    /// @notice The timestamp of the most recent daily execution.
    function lastDailyExecution() external view returns (uint256);

    /// @notice The timestamp of the most recent weekly execution.
    function lastWeeklyExecution() external view returns (uint256);

    /// @notice The timestamp of the most recent monthly execution.
    function lastMonthlyExecution() external view returns (uint256);

    /// @notice Whether the scheduler is currently paused.
    function schedulerPaused() external view returns (bool);

    /// @notice Whether `user` has been processed for `day`.
    function dailyProcessed(address user, uint256 day) external view returns (bool);

    /// @notice Whether `user` has been processed for `week`.
    function weeklyProcessed(address user, uint256 week) external view returns (bool);

    /// @notice Whether `user` has been processed for `month`.
    function monthlyProcessed(address user, uint256 month) external view returns (bool);

    /// @notice Whether `account` is authorized to mark daily/weekly/monthly processing.
    function authorizedCallers(address account) external view returns (bool);
}
