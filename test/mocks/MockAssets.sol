// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {NightshiftVault} from "../../src/NightshiftVault.sol";

/// @dev Test tokens are installed at the task's fixed token addresses using vm.etch.
contract MockToken is ERC20 {
    bool public failTransfers;
    bool public takeFee;
    address public callback;
    bytes public callbackData;

    constructor() ERC20("Test asset", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailure(bool value) external {
        failTransfers = value;
    }

    function setFee(bool value) external {
        takeFee = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (takeFee && from != address(0) && to != address(0) && amount != 0) {
            super._update(from, to, amount - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, amount);
        }
        if (callback != address(0) && from != address(0)) {
            (bool ok,) = callback.call(callbackData);
            require(!ok, "reentrancy unexpectedly succeeded");
        }
    }
}

contract RejectETH {
    receive() external payable {
        revert("rejected");
    }
}

/// @dev ERC-1271 wallet also attempts a nested withdrawal when receiving ETH.
contract TestWallet is IERC1271 {
    address public signer;
    NightshiftVault public vault;
    bytes32 public account;
    bool public reenter;
    bool public reentrySucceeded;
    bool public rejectETH;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signature);
        return error == ECDSA.RecoverError.NoError && recovered == signer
            ? IERC1271.isValidSignature.selector
            : bytes4(0xffffffff);
    }

    function configure(NightshiftVault vault_, bytes32 account_, bool reenter_, bool reject_) external {
        vault = vault_;
        account = account_;
        reenter = reenter_;
        rejectETH = reject_;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == signer, "wallet owner");
        (bool ok, bytes memory returned) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(returned, 32), mload(returned)) }
        }
        return returned;
    }

    receive() external payable {
        require(!rejectETH, "rejected");
        if (reenter) {
            (reentrySucceeded,) = address(vault).call(abi.encodeCall(vault.withdraw, (account, address(0), 1)));
        }
    }
}
