// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IV4PoolManager} from "../../src/interfaces/IV4PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUnlockReceiver {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Models the v4 unlock/swap/settle/take lifecycle, including signed packed deltas.
contract MockV4PoolManager is IV4PoolManager {
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address public constant HOOK = 0x42Ebcf86E3AB0445ba0362F911a7E8FAd6aCe0CC;
    address public locker;
    uint256 public output;
    uint256 public debt;
    uint256 public credit;
    bool public partialFill;
    bool public noOutput;
    bool public skipCallback;
    bool public repeatCallback;
    bool public failTake;
    bool public syncedETH;

    function configure(uint256 output_, bool partialFill_, bool noOutput_) external {
        output = output_;
        partialFill = partialFill_;
        noOutput = noOutput_;
    }

    function setFailures(bool skip, bool repeat, bool takeFails) external {
        skipCallback = skip;
        repeatCallback = repeat;
        failTake = takeFails;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "locked");
        locker = msg.sender;
        if (skipCallback) {
            locker = address(0);
            return abi.encode(output);
        }
        result = IUnlockReceiver(msg.sender).unlockCallback(data);
        if (repeatCallback) IUnlockReceiver(msg.sender).unlockCallback(data);
        require(debt == 0 && credit == 0, "unsettled");
        locker = address(0);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 balanceDelta)
    {
        require(msg.sender == locker, "not locker");
        require(key.currency0 == address(0) && key.currency1 == SHIFT, "currencies");
        require(key.fee == 12_500 && key.tickSpacing == 60 && key.hooks == HOOK, "pool");
        require(params.zeroForOne && params.amountSpecified < 0, "direction");
        require(params.sqrtPriceLimitX96 == 4_295_128_740 && hookData.length == 0, "parameters");
        debt = uint256(-params.amountSpecified);
        if (partialFill) debt /= 2;
        credit = noOutput ? 0 : output;
        require(debt <= uint256(uint128(type(int128).max)) && credit <= uint256(uint128(type(int128).max)));
        int128 amount0 = -int128(int256(debt));
        int128 amount1 = int128(int256(credit));
        return (int256(amount0) << 128) | int256(uint256(uint128(amount1)));
    }

    function sync(address currency) external {
        require(msg.sender == locker && currency == address(0), "sync");
        syncedETH = true;
    }

    function settle() external payable returns (uint256) {
        require(msg.sender == locker && syncedETH, "settle");
        require(msg.value == debt, "debt");
        debt = 0;
        syncedETH = false;
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == locker && currency == SHIFT && amount == credit && debt == 0, "take");
        require(!failTake, "take failed");
        credit = 0;
        require(IERC20(SHIFT).transfer(to, amount));
    }
}
