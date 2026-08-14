// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {ZeroAddress} from "../Errors/CommonErrors.sol";
import {AurexConstants} from "../Libraries/AurexConstants.sol";

/// @title AurexTokenImmutable
/// @author Aurex Protocol
/// @notice Non-upgradeable BEP-20 implementation of the Aurex (ARX) token: a fixed supply, no tax,
///         and a single expiring anti-snipe guard.
/// @dev
/// ## Why this exists alongside {AurexToken}
/// {AurexToken} is a UUPS proxy pair, which causes two problems for a token specifically:
///
/// 1. **Wallet discovery.** Mobile wallets resolve token metadata through indexer registries, and
///    some of those handle ERC-1967 proxies poorly. A plain, directly-verified contract is what the
///    ecosystem expects of a token.
/// 2. **Immutability as a guarantee.** A token whose logic the owner can replace is a token whose
///    holders are trusting the owner. Here the supply and the transfer rules are fixed at
///    deployment, and renouncing removes the last owner function entirely.
///
/// No proxy, no initializer, no upgrade path. Deploy, call {setPair} once, renounce.
///
/// ## Supply
/// A fixed 2,000,000 ARX minted once in the constructor. There is no `mint` function, so supply can
/// never grow; burning is the only way it changes, and only downward.
///
/// ## No transfer tax
/// Transfers are untaxed in every direction. An earlier revision carried a sell tax that scaled with
/// the drawdown from an all-time high, modelled on a comparable protocol. It was removed for two
/// reasons, both measured rather than assumed:
///
/// - **It was trivially avoidable.** The tier was derived from the spot price against the running
///   high, so anyone could lift the price fractionally above that high immediately before selling
///   and pay nothing. The tax would have fallen entirely on holders who did not know the trick.
/// - **It did nothing.** Simulation across healthy and failing deposit curves put the difference at
///   0.0% while deposits were growing — the tax only engages once the price is 10% below its high,
///   and while inflow is healthy the price sits *at* its high. The reference protocol's live tax
///   state has read `0%` for its entire existence.
///
/// A tax that cannot be enforced fairly and changes nothing is worse than no tax, because it can
/// never be corrected once ownership is renounced.
///
/// ## No buy restriction
/// Anyone may buy. Restricting purchases to protocol-controlled addresses would make the quoted
/// price unarbitrageable — with a deposit-funded buyback as the only permitted bid, the price would
/// track deposit inflow rather than demand, and no holder could verify it. It would also permanently
/// foreclose an exchange listing. The launch guard below covers the legitimate concern with a
/// bounded, expiring limit instead of a permanent one.
///
/// ## Launch guard
/// For {launchGuardDuration} after {setPair}, a single purchase from the pair may not exceed
/// {maxBuyDuringGuard}. This exists because the pool is seeded thin, so the opening buys move the
/// price furthest. The window is fixed at deployment, expires on its own, and cannot be re-armed,
/// extended, or pointed at particular addresses. {protocolBuyer} — the LiquidityManager running the
/// deposit-funded buyback — is exempt, so protocol operations are never blocked by it.
contract AurexTokenImmutable is ERC20, ERC20Burnable, Ownable {
    /// @notice The fixed total supply, minted in full by the constructor: 2,000,000 ARX.
    uint256 public constant MAX_SUPPLY = AurexConstants.TOTAL_SUPPLY;

    /// @notice How long after {setPair} the launch guard caps individual purchases.
    uint256 public immutable launchGuardDuration;

    /// @notice The largest single purchase permitted from the pair while the guard is active.
    uint256 public immutable maxBuyDuringGuard;

    /// @notice The DEX pair ARX trades against. Set once, via {setPair}.
    address public pancakePair;

    /// @notice The protocol's buyback executor, exempt from the launch-guard cap. Set once.
    address public protocolBuyer;

    /// @notice Timestamp {setPair} was called; the guard expires `launchGuardDuration` later.
    uint256 public tradingEnabledAt;

    /// @notice Emitted once, when the pair is wired and the guard window opens.
    event PairConfigured(address indexed pair, address indexed protocolBuyer, uint256 guardExpiresAt);

    /// @notice The pair may only be configured once.
    error PairAlreadyConfigured();

    /// @notice A purchase exceeded {maxBuyDuringGuard} while the launch guard was active.
    error LaunchGuardBuyLimitExceeded(uint256 attempted, uint256 limit);

    /// @notice Mints the entire supply and records the immutable launch-guard parameters.
    /// @dev When `owner_` and `liquidityWallet_` are the same address the whole supply lands there,
    ///      matching the single-wallet launch shape; otherwise it splits into the standard
    ///      1,900,000 / 100,000 allocation.
    /// @param owner_ Initial owner; receives {AurexConstants.OWNER_ALLOCATION}.
    /// @param liquidityWallet_ Receives {AurexConstants.INITIAL_LIQUIDITY_ARX} to seed the pool.
    /// @param launchGuardDuration_ Seconds the buy cap stays active after {setPair}. Zero disables it.
    /// @param maxBuyDuringGuard_ Largest single purchase while the guard is active. Ignored when the
    ///        duration is zero.
    constructor(address owner_, address liquidityWallet_, uint256 launchGuardDuration_, uint256 maxBuyDuringGuard_)
        ERC20("Aurex", "ARX")
        Ownable(owner_)
    {
        if (owner_ == address(0) || liquidityWallet_ == address(0)) revert ZeroAddress();

        launchGuardDuration = launchGuardDuration_;
        maxBuyDuringGuard = maxBuyDuringGuard_;

        if (owner_ == liquidityWallet_) {
            _mint(owner_, MAX_SUPPLY);
        } else {
            _mint(owner_, AurexConstants.OWNER_ALLOCATION);
            _mint(liquidityWallet_, AurexConstants.INITIAL_LIQUIDITY_ARX);
        }
    }

    /// @notice Wires the pair and the protocol's buyback executor. Callable once, then renounce.
    /// @dev Until this runs there is no pair, so no transfer is classified as a purchase and the
    ///      guard cannot fire — the token behaves as a plain ERC-20 throughout distribution. This is
    ///      the only owner function on the contract; once it has been called and ownership renounced,
    ///      nothing about the token can ever change.
    /// @param pair_ The ARX/USDT DEX pair.
    /// @param protocolBuyer_ The LiquidityManager, exempt from the guard cap.
    function setPair(address pair_, address protocolBuyer_) external onlyOwner {
        if (pancakePair != address(0)) revert PairAlreadyConfigured();
        if (pair_ == address(0) || protocolBuyer_ == address(0)) revert ZeroAddress();

        pancakePair = pair_;
        protocolBuyer = protocolBuyer_;
        tradingEnabledAt = block.timestamp;

        emit PairConfigured(pair_, protocolBuyer_, block.timestamp + launchGuardDuration);
    }

    /// @notice True while the launch guard is still capping individual purchases.
    function launchGuardActive() public view returns (bool) {
        uint256 startedAt = tradingEnabledAt;
        if (startedAt == 0 || launchGuardDuration == 0) return false;
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp < startedAt + launchGuardDuration;
    }

    /// @dev Applies the launch-guard cap to purchases, then settles the transfer. Mints and burns
    ///      (`from`/`to` zero) bypass it, as does every transfer that does not originate at the pair.
    ///      Selling is never restricted or taxed, at any price, at any time.
    function _update(address from, address to, uint256 amount) internal override {
        if (
            from == pancakePair && from != address(0) && to != protocolBuyer && launchGuardActive()
                && amount > maxBuyDuringGuard
        ) {
            revert LaunchGuardBuyLimitExceeded(amount, maxBuyDuringGuard);
        }

        super._update(from, to, amount);
    }
}
