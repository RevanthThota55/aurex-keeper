// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IInvestmentManager
/// @author Aurex Protocol
/// @notice Types, events and integration surface for the protocol {InvestmentManager}.
/// @dev The Investment Manager owns user onboarding, the referral tree and the package
///      lifecycle (purchase / upgrade). It never pays money, transfers rewards or
///      calculates ROI — those responsibilities belong to other modules.
interface IInvestmentManager {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice On-chain record of a protocol user.
    /// @param registered Whether the wallet has an account.
    /// @param active Whether the wallet currently holds an active package.
    /// @param referrer The wallet that referred this user (zero for the root account).
    /// @param packageAmount The size of the currently active package, in USDT base units.
    /// @param totalInvested The lifetime amount invested (initial package + all upgrade diffs).
    /// @param packageStart The timestamp at which the current package became active.
    /// @param packageId The protocol-wide id of the current package instance.
    /// @param upgradeCount The number of times the user has upgraded.
    struct User {
        bool registered;
        bool active;
        address referrer;
        uint256 packageAmount;
        uint256 totalInvested;
        uint256 packageStart;
        uint256 packageId;
        uint256 upgradeCount;
    }

    /// @notice Lifecycle state of a single investment (one independent ROI stream).
    /// @param Active The investment is accruing ROI (within its duration and below its ROI cap).
    /// @param Completed The investment has finished accruing (duration elapsed or ROI cap reached).
    enum InvestmentStatus {
        Active,
        Completed
    }

    /// @notice A single investment record — an independent, non-overwritable ROI stream with its
    ///         own **frozen** economics.
    /// @dev Every investment event (first investment, re-topup, auto-reinvestment) appends one of
    ///      these; existing records are never mutated except to accumulate `roiEarned` and to flip
    ///      `status` to {InvestmentStatus.Completed}. As of the corrective phase the ROI economics
    ///      are **snapshotted at creation** (`roiPercentage`, `roiDurationDays`, `maxRoiPercentage`,
    ///      `oraclePrice`) and are the values the {ProtocolEngine} uses for this stream forever —
    ///      later ProtocolConfig changes never retroactively alter a historical investment. When the
    ///      snapshot fields are zero (e.g. an investment created before a ProtocolConfig was wired),
    ///      the engine falls back to the live ProtocolConfig for backward compatibility.
    /// @param amount The principal of this investment, in USDT base units.
    /// @param startTime The timestamp this ROI stream started (its own independent clock).
    /// @param roiEarned The cumulative daily-ROI recorded against this investment, in USDT base units.
    /// @param packageId The protocol-wide package id assigned when this investment was created.
    /// @param status Whether this investment is still accruing ROI or has completed.
    /// @param roiPercentage The daily-ROI rate frozen at creation, in basis points (0 = use live config).
    /// @param roiDurationDays The ROI accrual duration frozen at creation, in days (0 = use live config).
    /// @param maxRoiPercentage The lifetime ROI cap frozen at creation, in basis points (0 = use live config).
    /// @param oraclePrice The ARX/USDT oracle price frozen at creation, in USDT base units per whole ARX.
    struct Investment {
        uint256 amount;
        uint256 startTime;
        uint256 roiEarned;
        uint256 packageId;
        InvestmentStatus status;
        uint256 roiPercentage;
        uint256 roiDurationDays;
        uint256 maxRoiPercentage;
        uint256 oraclePrice;
    }

    /// @notice Per-user automatic-reinvestment configuration.
    /// @param enabled Whether automatic reinvestment is enabled for the user.
    /// @param amount The amount each automatic reinvestment invests, in USDT base units.
    /// @param lastExecuted The timestamp of the user's most recent automatic reinvestment (zero if none).
    struct AutoReinvestConfig {
        bool enabled;
        uint256 amount;
        uint256 lastExecuted;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a wallet registers an account.
    /// @param user The newly registered wallet.
    /// @param referrer The referrer (zero for the root account).
    event UserRegistered(address indexed user, address indexed referrer);

    /// @notice Emitted when a user purchases their first package.
    /// @param user The purchasing wallet.
    /// @param packageId The protocol-wide id assigned to the package.
    /// @param amount The package amount, in USDT base units.
    event PackagePurchased(address indexed user, uint256 indexed packageId, uint256 amount);

    /// @notice Emitted when a user upgrades to a larger package.
    /// @param user The upgrading wallet.
    /// @param packageId The protocol-wide id assigned to the new package.
    /// @param previousAmount The package amount before the upgrade.
    /// @param newAmount The package amount after the upgrade.
    event PackageUpgraded(address indexed user, uint256 indexed packageId, uint256 previousAmount, uint256 newAmount);

    /// @notice Emitted when the owner updates the Treasury address.
    /// @param previousTreasury The prior Treasury address.
    /// @param newTreasury The new Treasury address.
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    /// @notice Emitted when a new investment record (ROI stream) is created for `user`.
    /// @param user The investor.
    /// @param investmentIndex The zero-based index of the record in the user's investment history.
    /// @param packageId The protocol-wide package id assigned to the investment.
    /// @param amount The investment principal, in USDT base units.
    /// @param startTime The timestamp the investment's ROI stream started.
    event InvestmentCreated(
        address indexed user, uint256 indexed investmentIndex, uint256 packageId, uint256 amount, uint256 startTime
    );

    /// @notice Emitted when a newly created investment becomes the user's active package.
    /// @param user The investor.
    /// @param investmentIndex The zero-based index of the activated record.
    /// @param packageId The protocol-wide package id of the activated investment.
    event InvestmentActivated(address indexed user, uint256 indexed investmentIndex, uint256 packageId);

    /// @notice Emitted when an investment finishes accruing ROI (duration elapsed or ROI cap reached).
    /// @param user The investor.
    /// @param investmentIndex The zero-based index of the completed record.
    /// @param roiEarned The final cumulative ROI recorded against the investment, in USDT base units.
    event InvestmentCompleted(address indexed user, uint256 indexed investmentIndex, uint256 roiEarned);

    /// @notice Emitted when daily ROI is recorded against a specific investment.
    /// @param user The investor.
    /// @param investmentIndex The zero-based index of the credited record.
    /// @param amount The ROI amount added in this recording, in USDT base units.
    /// @param roiEarned The investment's cumulative ROI after this recording, in USDT base units.
    event InvestmentROIRecorded(
        address indexed user, uint256 indexed investmentIndex, uint256 amount, uint256 roiEarned
    );

    /// @notice Emitted when an existing active user re-tops up (invests again).
    /// @param user The investor.
    /// @param packageId The protocol-wide package id assigned to the re-topup.
    /// @param amount The re-topup amount, in USDT base units.
    event ReTopupStarted(address indexed user, uint256 indexed packageId, uint256 amount);

    /// @notice Emitted when a re-topup completes its full lifecycle (record + allocation + rewards).
    /// @param user The investor.
    /// @param packageId The protocol-wide package id assigned to the re-topup.
    /// @param amount The re-topup amount, in USDT base units.
    event ReTopupCompleted(address indexed user, uint256 indexed packageId, uint256 amount);

    /// @notice Emitted when a user enables automatic reinvestment.
    /// @param user The user.
    /// @param amount The configured amount each automatic reinvestment invests, in USDT base units.
    event AutoReinvestmentEnabled(address indexed user, uint256 amount);

    /// @notice Emitted when a user disables automatic reinvestment.
    /// @param user The user.
    event AutoReinvestmentDisabled(address indexed user);

    /// @notice Emitted when an automatic reinvestment is executed for `user`.
    /// @param user The user.
    /// @param packageId The protocol-wide package id assigned to the reinvestment.
    /// @param amount The reinvested amount, in USDT base units.
    event AutoReinvestmentExecuted(address indexed user, uint256 indexed packageId, uint256 amount);

    /// @notice Emitted when the owner updates the InvestmentLifecycleEngine address.
    event LifecycleEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the owner updates the RankEngine address (daily-limit scaling).
    event RankEngineUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a pre-registry user is backfilled into the on-chain network registry.
    event NetworkRegistryBackfilled(address indexed user, address indexed referrer);

    /// @notice Emitted when the owner updates the company wallet (instant treasury-share payout).
    event CompanyWalletUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the registry length is repaired after the mis-ordered upgrade.
    event RegistryLengthRepaired(uint256 newLength);

    /// @notice Emitted when a deposit's company share is transferred instantly at deposit time.
    /// @param payer The depositing user.
    /// @param wallet The company wallet credited.
    /// @param amount The company share, in USDT base units.
    event CompanyShareTransferred(address indexed payer, address indexed wallet, uint256 amount);

    /// @notice Emitted when the LiquidityManager used for the deposit-funded buyback is updated.
    event LiquidityManagerUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a deposit's buyback share is routed to the LiquidityManager.
    /// @param payer The depositing user.
    /// @param amount The buyback share, in USDT base units.
    /// @param executed False when the DEX leg could not run; the share falls through to the Treasury.
    /// @param liquidity LP tokens minted to the Treasury by this deposit.
    event BuybackFunded(address indexed payer, uint256 amount, bool executed, uint256 liquidity);

    /// @notice Emitted when a contract is authorized to record ROI / execute auto-reinvestment.
    event AuthorizedContractAdded(address indexed account);

    /// @notice Emitted when a contract's authorization is revoked.
    event AuthorizedContractRemoved(address indexed account);

    // -------------------------------------------------------------------------
    // Protocol operations
    // -------------------------------------------------------------------------

    /// @notice Registers the caller (first call) and purchases their first package.
    /// @param amount The package amount, in USDT base units (>= the configured minimum, a whole
    ///        multiple of the configured step).
    /// @param referrer The referring account (must already be registered).
    function invest(uint256 amount, address referrer) external;

    /// @notice Upgrades the caller's active package to a larger amount, paying the difference.
    /// @param newAmount The new package amount, in USDT base units (>= current, a whole multiple of
    ///        the configured step).
    function upgradePackage(uint256 newAmount) external;

    /// @notice Re-tops up: an existing active user invests again, creating a new independent ROI
    ///         stream that runs through the same investment lifecycle as a first investment.
    /// @param amount The re-topup amount, in USDT base units (>= the configured minimum, a whole
    ///        multiple of the configured step).
    function reTopup(uint256 amount) external;

    /// @notice Enables or updates (or, when `enabled` is false, disables) the caller's automatic
    ///         reinvestment configuration.
    /// @param enabled Whether automatic reinvestment should be enabled.
    /// @param amount The amount each automatic reinvestment invests, in USDT base units (validated
    ///        against the package rules and the ProtocolConfig reinvest bounds when `enabled`).
    function setAutoReinvestment(bool enabled, uint256 amount) external;

    /// @notice Executes one automatic reinvestment for `user` using their configured amount.
    /// @dev Restricted to authorized automation. Reuses the same investment lifecycle as a manual
    ///      re-topup; funds are pulled from `user` (who must have opted in and approved this
    ///      contract). Respects the global toggle, the reinvest bounds and the reinvest cooldown.
    /// @param user The user to reinvest for.
    function executeAutoReinvestment(address user) external;

    /// @notice Records daily ROI against a user's investments (one entry per index).
    /// @dev Restricted to authorized recorders (the ProtocolEngine). The engine performs the ROI
    ///      calculation; this contract only stores the results — it accumulates each investment's
    ///      `roiEarned` and flips completed investments to {InvestmentStatus.Completed}.
    /// @param user The investor whose investments are credited.
    /// @param roiAmounts The ROI amount to add per investment index (zero to skip), in USDT base units.
    /// @param completedFlags Whether each investment index should be marked completed after crediting.
    function recordInvestmentROIBatch(address user, uint256[] calldata roiAmounts, bool[] calldata completedFlags)
        external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Whether `user` has a registered account.
    function isRegistered(address user) external view returns (bool);

    /// @notice Returns the full {User} record for `user`.
    function getUser(address user) external view returns (User memory);

    /// @notice Returns the active package summary for `user`.
    /// @return packageId The current package id.
    /// @return packageAmount The current package amount.
    /// @return packageStart The timestamp the current package became active.
    /// @return active Whether the package is active.
    function getPackage(address user)
        external
        view
        returns (uint256 packageId, uint256 packageAmount, uint256 packageStart, bool active);

    /// @notice Returns `user`'s full investment history (every ROI stream ever created).
    /// @dev History is immutable except for `roiEarned` accumulation and `status` completion.
    function getInvestments(address user) external view returns (Investment[] memory);

    /// @notice Returns a single investment record for `user` at `index`.
    function getInvestment(address user, uint256 index) external view returns (Investment memory);

    /// @notice Returns the number of investment records `user` holds.
    function investmentCount(address user) external view returns (uint256);

    /// @notice Returns `user`'s automatic-reinvestment configuration.
    function getAutoReinvestConfig(address user) external view returns (AutoReinvestConfig memory);

    /// @notice Returns `user`'s cumulative deposits for the current UTC day, in USDT base units
    ///         (counts toward the rank-scaled daily deposit limit).
    function dailyDepositedToday(address user) external view returns (uint256);

    // -------------------------------------------------------------------------
    // On-chain network registry (log-free enumeration for keepers + the tree UI)
    // -------------------------------------------------------------------------

    /// @notice The number of wallets in the on-chain registry (every registration since the
    ///         registry existed, excluding the root).
    function registeredUserCount() external view returns (uint256);

    /// @notice The registered wallet at `index` (registration order). Reverts out-of-bounds.
    function userAt(uint256 index) external view returns (address);

    /// @notice The number of direct referrals `referrer` has in the registry.
    function directReferralCount(address referrer) external view returns (uint256);

    /// @notice A page of `referrer`'s direct referrals, in registration order.
    /// @param referrer The upline whose directs are listed.
    /// @param offset The zero-based start index.
    /// @param limit The maximum entries to return (`0` = to the end).
    function getDirectReferrals(address referrer, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page);

    /// @notice The configured Treasury address (owner-updatable).
    function treasury() external view returns (address);

    /// @notice The configured USDT token address (fixed after initialization).
    function usdt() external view returns (address);

    /// @notice The configured ARX token address (fixed after initialization).
    function arx() external view returns (address);

    /// @notice The total number of registered accounts (including the root).
    function totalUsers() external view returns (uint256);

    /// @notice The total number of investment records ever created across all users.
    function totalInvestments() external view returns (uint256);

    /// @notice The configured InvestmentLifecycleEngine the manager routes investments through
    ///         (owner-updatable; zero until wired, in which case routing is skipped).
    function lifecycleEngine() external view returns (address);

    /// @notice Whether `account` is authorized to record ROI / execute automatic reinvestment.
    function authorizedContracts(address account) external view returns (bool);

    /// @notice Whether investments are paused at the module level.
    function investmentsPaused() external view returns (bool);
}
