// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAurexToken
/// @author Aurex Protocol
/// @notice External interface for the Aurex (ARX) token.
/// @dev Extends the standard ERC-20 interface with the two additions that make the
///      token BEP-20 friendly: {getOwner} and the fixed {MAX_SUPPLY} cap. Burn
///      functionality is inherited from OpenZeppelin's `ERC20Burnable` and is part of
///      the standard ERC-20 surface, so it is not re-declared here.
interface IAurexToken is IERC20 {
    /// @notice Returns the current owner (administrator) of the token.
    /// @dev BEP-20 compatibility accessor; mirrors OpenZeppelin's `owner()`.
    /// @return The owner address.
    function getOwner() external view returns (address);

    /// @notice Returns the fixed maximum supply of the token, in the smallest unit (wei).
    /// @dev The entire supply is minted once during initialization and can only ever
    ///      decrease via burning; it can never increase.
    /// @return The maximum supply (2,000,000 * 1e18).
    function MAX_SUPPLY() external view returns (uint256);
}
