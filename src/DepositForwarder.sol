// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DepositForwarder
/// @notice A personal deposit address with an immutable vault and account.
/// @dev Created only as needed by NightshiftVault. There is no arbitrary recipient or external execution.
contract DepositForwarder {
    using SafeERC20 for IERC20;

    address public immutable vault;
    bytes32 public immutable accountId;

    error OnlyVault();
    error ETHTransferFailed();
    error InvalidConfiguration();

    event Forwarded(bytes32 indexed accountId, address indexed asset, uint256 amount);

    constructor(address vault_, bytes32 accountId_) {
        if (vault_ == address(0) || accountId_ == bytes32(0)) revert InvalidConfiguration();
        vault = vault_;
        accountId = accountId_;
    }

    /// @notice Accepts ETH from wallets or exchanges without forwarding during receipt.
    receive() external payable {}

    /// @notice Sends the entire asset balance only to this forwarder's vault.
    /// @dev The vault authenticates the account and credits the amount actually received.
    function sweep(address asset) external returns (uint256 amount) {
        if (msg.sender != vault) revert OnlyVault();
        if (asset == address(0)) {
            amount = address(this).balance;
            emit Forwarded(accountId, asset, amount);
            if (amount != 0) {
                (bool ok,) = payable(vault).call{value: amount}("");
                if (!ok) revert ETHTransferFailed();
            }
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            emit Forwarded(accountId, asset, amount);
            if (amount != 0) IERC20(asset).safeTransfer(vault, amount);
        }
    }
}
