// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Squeek (SQUEEK)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 SQUEEK (18 decimals) is
/// minted once, in the constructor, to the deployer (`msg.sender`). Nothing can mint afterwards.
/// @dev Deliberately minimal:
/// - no owner, admin, minter or pauser role of any kind;
/// - no mint, burn, blacklist, freeze, fee or tax hooks;
/// - no constructor arguments, so the creation code is fully determined by this source;
/// - no delegatecall, selfdestruct or external calls anywhere in the runtime.
/// Transfers, approvals and `transferFrom` behave exactly as OpenZeppelin's `ERC20` v5 defines them:
/// every amount sent arrives whole, and `totalSupply()` is constant for the life of the contract.
/// The contract identifier is `SqueekToken`; the token's own name and symbol are returned by
/// `name()` and `symbol()`.
contract SqueekToken is ERC20 {
    /// @notice The token name returned by `name()`.
    string public constant TOKEN_NAME = "Squeek";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SQUEEK";

    /// @notice Decimals of the token. Fixed at 18, the ERC-20 default.
    uint8 public constant DECIMALS = 18;

    /// @notice The entire supply ever to exist, in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. There is no other mint path.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
