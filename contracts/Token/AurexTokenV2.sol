// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {ZeroAddress} from "../Errors/CommonErrors.sol";
import {AurexConstants} from "../Libraries/AurexConstants.sol";

/// @title AurexTokenV2
/// @author Aurex Protocol
/// @notice Replacement for {AurexTokenImmutable}. Identical name, symbol, decimals and supply; the
///         only behavioural change is that the public may sell on the DEX but not buy.
/// @dev
/// ## Difference from v1, in one paragraph
/// v1 carried a *launch guard*: for seven days after {setPair}, a single purchase could not exceed
/// 100 ARX. It expired on its own and was gone. This contract replaces that with a permanent
/// restriction — every transfer out of the registered pair reverts unless the receiver is the
/// protocol's buy-side executor or the liquidity wallet — plus a **one-way release** so the market
/// can be opened later if the business ever needs it. Everything else is unchanged.
///
/// ## The release switch, and why it is one-way
/// {liftBuyRestriction} is held by {guardAdmin}, an address fixed at construction that is
/// deliberately **separate from `Ownable`**. Renouncing ownership does not touch it. That is the
/// behaviour asked for: the token can be renounced for credibility while the operator keeps the
/// ability to open trading for an exchange listing.
///
/// It only ever moves in one direction. Once buying is open it can never be closed again — there is
/// no re-arm function and no way to add one, because the contract is not upgradeable. The strongest
/// thing the admin key can do is *give* people the right to buy. It can never take a balance, block
/// a sale, freeze a wallet, mint, or tax.
///
/// That asymmetry is the whole justification for keeping a key past renouncement. A switch that
/// could re-block buying would leave holders trusting the operator, which is what renouncing is
/// supposed to rule out.
///
/// **This must be disclosed.** A token advertised as "renounced, cannot be changed" while a second
/// key can still alter transfer behaviour is the exact shape of a scam contract, and detectors
/// score it that way. State plainly that ownership is renounced AND that a separate admin key can
/// permanently open buying — never the first half alone.
///
/// ## Liquidity stays recoverable
/// {liquidityWallet} is buy-exempt, so it can withdraw pool liquidity in a single transaction.
/// This is not cosmetic: on v1 the launch guard blocked the owner from redeeming their own LP,
/// because removing liquidity moves tokens out of the pair and is indistinguishable from a
/// purchase. Recovering it took thirteen chunked transactions. That exemption is the fix.
///
/// ## Inherited limitations
/// - **An outside liquidity provider cannot withdraw the ARX side.** Same cause: redemption looks
///   like a purchase. Only {liquidityWallet} and {protocolBuyer} escape it. This is the one way the
///   design can cost an outsider money and it must be published, not buried.
/// - **Only the registered pair is covered.** Anyone may create a second pair and trade freely
///   there. Closing that would need an owner function to register more pairs, which forfeits
///   renouncement — and the supply available to seed a rival pool is only what the protocol pays out.
///
/// ## No transfer tax
/// Not reproduced from the reference implementation. v1 records why and it still holds: the tier is
/// derived from spot against a running high, so anyone can lift the price fractionally above that
/// high immediately before selling and pay nothing, leaving the tax on holders who do not know the
/// trick. The reference token's own `sellTaxBP()` has read `0` for its entire existence.
///
/// ## Lifecycle
/// Deploy → distribute → create and seed the pair → {setPair} → verify → renounce ownership.
/// The pair must exist and be seeded *before* {setPair}: afterwards only the exempt addresses can
/// receive from it. Renouncing before {setPair} bricks the token permanently — unlike v1 there is
/// no expiring guard to fall back on.
contract AurexTokenV2 is ERC20, ERC20Burnable, Ownable {
    /// @notice The fixed total supply, minted in full by the constructor: 2,000,000 ARX.
    uint256 public constant MAX_SUPPLY = AurexConstants.TOTAL_SUPPLY;

    /// @notice The only address that may lift the buy restriction. Fixed at construction and
    ///         independent of {Ownable}, so renouncing ownership leaves it intact.
    /// @dev Immutable by design. It cannot be rotated, so treat the key as unrecoverable: losing it
    ///      means buying stays closed forever, which is the intended default anyway.
    address public immutable guardAdmin;

    /// @notice Seeds and manages pool liquidity, and may receive from the pair so that liquidity
    ///         remains withdrawable in one transaction. Fixed at construction.
    address public immutable liquidityWallet;

    /// @notice The DEX pair ARX trades against. Set once, via {setPair}.
    address public pancakePair;

    /// @notice The protocol's buy-side executor, permitted to receive from the pair. Set once.
    address public protocolBuyer;

    /// @notice Once true, anyone may buy and this can never be reversed.
    bool public buyRestrictionLifted;

    /// @notice Emitted once, when the pair is wired and the restriction becomes effective.
    event PairConfigured(address indexed pair, address indexed protocolBuyer);

    /// @notice Emitted once, when buying is opened permanently.
    event BuyRestrictionLifted(address indexed by);

    /// @notice The pair may only be configured once.
    error PairAlreadyConfigured();

    /// @notice A purchase was attempted by an address not permitted to receive from the pair.
    error BuyRestricted(address receiver);

    /// @notice Only {guardAdmin} may lift the restriction.
    error NotGuardAdmin();

    /// @notice Buying is already open; the release is one-way.
    error BuyRestrictionAlreadyLifted();

    /// @notice Mints the entire supply. Metadata matches v1 exactly so wallets read it the same.
    /// @param owner_ Initial owner; receives {AurexConstants.OWNER_ALLOCATION}. Renounce after setup.
    /// @param liquidityWallet_ Receives {AurexConstants.INITIAL_LIQUIDITY_ARX} and is buy-exempt.
    /// @param guardAdmin_ Keeps the one-way release after ownership is renounced.
    constructor(address owner_, address liquidityWallet_, address guardAdmin_)
        ERC20("Aurex", "ARX")
        Ownable(owner_)
    {
        if (owner_ == address(0) || liquidityWallet_ == address(0) || guardAdmin_ == address(0)) {
            revert ZeroAddress();
        }

        liquidityWallet = liquidityWallet_;
        guardAdmin = guardAdmin_;

        if (owner_ == liquidityWallet_) {
            _mint(owner_, MAX_SUPPLY);
        } else {
            _mint(owner_, AurexConstants.OWNER_ALLOCATION);
            _mint(liquidityWallet_, AurexConstants.INITIAL_LIQUIDITY_ARX);
        }
    }

    /// @notice Wires the pair and the buy-side executor. Callable once, then renounce.
    /// @dev Until this runs nothing is classified as a purchase, so distribution and pool seeding
    ///      behave like a plain ERC-20. This is the only `onlyOwner` function on the contract.
    function setPair(address pair_, address protocolBuyer_) external onlyOwner {
        if (pancakePair != address(0)) revert PairAlreadyConfigured();
        if (pair_ == address(0) || protocolBuyer_ == address(0)) revert ZeroAddress();

        pancakePair = pair_;
        protocolBuyer = protocolBuyer_;

        emit PairConfigured(pair_, protocolBuyer_);
    }

    /// @notice Opens buying to everyone, permanently. Callable only by {guardAdmin}.
    /// @dev Survives {renounceOwnership} because {guardAdmin} is not the owner. One-way: there is
    ///      no counterpart that restores the restriction, and none can be added — no proxy exists.
    function liftBuyRestriction() external {
        if (msg.sender != guardAdmin) revert NotGuardAdmin();
        if (buyRestrictionLifted) revert BuyRestrictionAlreadyLifted();

        buyRestrictionLifted = true;
        emit BuyRestrictionLifted(msg.sender);
    }

    /// @notice Whether `receiver` may currently receive ARX from the pair.
    /// @dev Lets the protocol, the frontend and reviewers assert the rule without simulating a
    ///      transfer. True for everyone once the restriction is lifted.
    function canReceiveFromPair(address receiver) external view returns (bool) {
        if (pancakePair == address(0)) return false;
        if (buyRestrictionLifted) return true;
        return receiver == protocolBuyer || receiver == liquidityWallet;
    }

    /// @dev Rejects purchases while the restriction stands, then settles the transfer.
    ///
    ///      A purchase is any movement whose sender is the registered pair. Mints carry
    ///      `from == address(0)` and burns `to == address(0)`; neither can match a configured pair,
    ///      so both pass through, as does every transfer that does not originate at the pair —
    ///      wallet to wallet, treasury payouts, and selling into the pool included.
    ///
    ///      Selling is never restricted and never taxed, at any price, at any time.
    function _update(address from, address to, uint256 amount) internal override {
        address pair = pancakePair;
        if (
            !buyRestrictionLifted && pair != address(0) && from == pair && to != protocolBuyer
                && to != liquidityWallet
        ) {
            revert BuyRestricted(to);
        }

        super._update(from, to, amount);
    }
}
