// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The subset of Uniswap v4 PoolManager's ABI needed for the fixed ETH/SHIFT swap.
/// @dev Address currencies and hooks have the same ABI encoding as v4's Currency and IHooks types.
interface IV4PoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 balanceDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}
