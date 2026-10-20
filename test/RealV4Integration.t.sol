// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {MockToken} from "./mocks/MockAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @dev The production hook is external; this local hook supplies the callbacks enabled by its address bits.
contract IntegrationHook {
    NightshiftVault public vault;
    bool public reentrySucceeded;
    uint256 public beforeCalls;
    uint256 public afterCalls;

    function configure(NightshiftVault vault_) external {
        vault = vault_;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(sender == address(vault), "unexpected swap caller");
        ++beforeCalls;
        // Must be rejected even while the outer burn legitimately allows the PoolManager callback.
        (reentrySucceeded,) = address(vault).call(abi.encodeCall(vault.sweep, (keccak256("alice"), address(0))));
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        ++afterCalls;
        return (IHooks.afterSwap.selector, 0);
    }
}

contract IntegrationLiquidity {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function seed(PoolKey memory key) external {
        manager.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        PoolKey memory key = abi.decode(data, (PoolKey));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 100 ether, bytes32(0)), "");
        uint256 ethOwed = uint256(-int256(delta.amount0()));
        uint256 shiftOwed = uint256(-int256(delta.amount1()));
        manager.sync(key.currency0);
        manager.settle{value: ethOwed}();
        manager.sync(key.currency1);
        require(IERC20(Currency.unwrap(key.currency1)).transfer(address(manager), shiftOwed));
        manager.settle();
        return "";
    }

    receive() external payable {}
}

/// @dev No fork or network: tests the vault ABI against vendored, unmodified Uniswap v4.0.0 core.
contract RealV4IntegrationTest is VaultTestBase {
    IPoolManager private manager;
    IntegrationHook private hook;

    function setUp() public override {
        super.setUp();
        // Running creation code at the destination correctly sets NoDelegateCall's immutable original.
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), vault.POOL_MANAGER());
        manager = IPoolManager(vault.POOL_MANAGER());
        IntegrationHook implementation = new IntegrationHook();
        vm.etch(vault.SHIFT_HOOK(), address(implementation).code);
        hook = IntegrationHook(vault.SHIFT_HOOK());
        hook.configure(vault);
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(shift), 12_500, 60, IHooks(address(hook)));
        manager.initialize(key, uint160(1 << 96));
        IntegrationLiquidity liquidity = new IntegrationLiquidity(manager);
        vm.deal(address(liquidity), 100 ether);
        MockToken(shift).mint(address(liquidity), 100 ether);
        liquidity.seed(key);
    }

    function test_realV4SwapSettlesDeltasCallsHookAndBurnsOnlyNewOutput() public {
        _deposit(A, shift, 10 ether);
        _deposit(A, address(0), 5 ether);
        _direct(A, address(0), 2 ether);
        uint256 managerETH = address(manager).balance;
        uint256 managerSHIFT = IERC20(shift).balanceOf(address(manager));
        vm.prank(keeper);
        uint256 output = vault.burnReserve(1 ether, 0.9 ether);
        assertGe(output, 0.9 ether);
        assertLt(output, 1 ether);
        assertEq(IERC20(shift).balanceOf(vault.DEAD()), output);
        assertEq(IERC20(shift).balanceOf(address(manager)), managerSHIFT - output);
        assertEq(address(manager).balance, managerETH + 1 ether);
        assertEq(_available(A, shift), 10 ether);
        assertEq(_available(A, address(0)), 5 ether);
        assertEq(vault.burnReserve(), 0);
        assertEq(hook.beforeCalls(), 1);
        assertEq(hook.afterCalls(), 1);
        assertFalse(hook.reentrySucceeded());
        _assertSolvent();
    }

    function test_realV4MinimumOutputRollbackPreservesReserveAndPool() public {
        _direct(A, address(0), 2 ether);
        uint256 managerETH = address(manager).balance;
        uint256 managerSHIFT = IERC20(shift).balanceOf(address(manager));
        vm.expectRevert(NightshiftVault.SlippageExceeded.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 1 ether);
        assertEq(vault.burnReserve(), 1 ether);
        assertEq(address(manager).balance, managerETH);
        assertEq(IERC20(shift).balanceOf(address(manager)), managerSHIFT);
        assertEq(IERC20(shift).balanceOf(vault.DEAD()), 0);
        _assertSolvent();
    }
}
