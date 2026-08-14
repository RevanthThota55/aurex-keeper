// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import {ZeroAddress} from "../Errors/CommonErrors.sol";
import {IAurexToken} from "../Interfaces/IAurexToken.sol";
import {AurexConstants} from "../Libraries/AurexConstants.sol";

/// @title AurexToken
/// @author Aurex Protocol
/// @notice UUPS-upgradeable, BEP-20 compatible implementation of the Aurex (ARX) token.
/// @dev
/// ## Standard
/// A pure ERC-20 / BEP-20 token with 18 decimals and a **fixed** supply of
/// 2,000,000 ARX. It is burnable (via OpenZeppelin's `ERC20Burnable`) and carries
/// **no** transfer/buy/sell tax, fee wallet, blacklist, whitelist, anti-whale,
/// anti-bot, cooldown or trading lock. Transfers, approvals and burns are the only
/// state-changing token operations.
///
/// ## Supply
/// The entire supply is minted exactly once, inside {initialize}: 1,900,000 ARX to
/// the owner and 100,000 ARX to the liquidity wallet. No mint function is exposed,
/// so supply can never grow afterwards; burning is the only way it can change, and it
/// can only ever decrease. {MAX_SUPPLY} records the immutable cap.
///
/// ## Upgradeability
/// This is the logic implementation of a UUPS (ERC-1967) proxy pair. It must be
/// deployed behind an `ERC1967Proxy`; all state lives in the proxy. The constructor
/// locks this implementation with `_disableInitializers()`, and only the owner may
/// authorize an upgrade via {_authorizeUpgrade}. The owner may also transfer or
/// renounce ownership through the inherited `Ownable` functions.
contract AurexToken is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IAurexToken
{
    /// @notice The fixed maximum supply, minted in full during {initialize}: 2,000,000 ARX.
    /// @dev Exposed as a constant so integrators can read the cap without an SLOAD. The
    ///      supply can only ever decrease from this value (via burning), never increase.
    uint256 public constant override MAX_SUPPLY = AurexConstants.TOTAL_SUPPLY;

    /// @notice Reserved storage slots so future upgrades can add state without shifting
    ///         the layout of variables declared here.
    /// @dev See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    uint256[50] private __gap;

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @dev Initialization happens once, on the proxy, via {initialize}.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the token: sets metadata and ownership, then mints the full supply.
    /// @dev Callable exactly once, on the proxy (guarded by `initializer`). Mints
    ///      {AurexConstants.OWNER_ALLOCATION} to `owner_` and
    ///      {AurexConstants.INITIAL_LIQUIDITY_ARX} to `liquidityWallet_`; together these
    ///      equal {MAX_SUPPLY}. This is the only place `_mint` is ever reached, so no
    ///      further supply can be created after this call returns.
    /// @param owner_ Protocol administrator; receives the owner allocation and upgrade rights.
    /// @param liquidityWallet_ Wallet that receives the ARX reserved for initial liquidity.
    function initialize(address owner_, address liquidityWallet_) external initializer {
        if (owner_ == address(0) || liquidityWallet_ == address(0)) revert ZeroAddress();

        __ERC20_init(AurexConstants.TOKEN_NAME, AurexConstants.TOKEN_SYMBOL);
        __ERC20Burnable_init();
        __Ownable_init(owner_);

        _mint(owner_, AurexConstants.OWNER_ALLOCATION);
        _mint(liquidityWallet_, AurexConstants.INITIAL_LIQUIDITY_ARX);
    }

    /// @notice Returns the current owner (administrator) of the token.
    /// @dev BEP-20 compatibility accessor; mirrors the inherited `owner()`.
    /// @return The owner address.
    function getOwner() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Restricts upgrades to the owner. The parameter name is omitted intentionally
    ///      to avoid an unused-variable warning.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
