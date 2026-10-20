// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "./mocks/MockAssets.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";

contract ShopAndBurnTest is VaultTestBase {
    function test_ownerAndDirectPurchasesSplitExactlyAllAssets() public {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            uint256 amount = 2 ether;
            _deposit(A, asset, amount);
            vm.prank(alice);
            vault.buy(A, ITEM, asset, amount);
            assertEq(_available(A, asset), 0);
            assertEq(vault.pot(asset), amount / 2);
            assertEq(vault.spentInLast24Hours(A, asset), 0);
            _direct(A, asset, amount);
            assertEq(vault.pot(asset), amount);
            if (asset == address(0)) assertEq(vault.burnReserve(), amount);
            else assertEq(_balance(asset == imd ? vault.IMD_BURN_EXECUTOR() : vault.DEAD(), asset), amount);
            _assertSolvent();
        }
    }

    function test_operatorShopAndGamesShareDailyCapAllAssets() public {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            (uint256 daily, uint256 stake) = vault.caps(A, asset);
            _deposit(A, asset, 2 * daily);
            _deposit(B, asset, daily);
            _lock(bytes32(i + 1), asset, stake);
            vm.prank(op);
            vault.buy(A, ITEM, asset, daily - stake);
            assertEq(vault.spentInLast24Hours(A, asset), daily);
            vm.expectRevert(NightshiftVault.CapExceeded.selector);
            vm.prank(op);
            vault.buy(A, ITEM, asset, 2);
            vm.expectRevert(NightshiftVault.CapExceeded.selector);
            _lock(bytes32(i + 5), asset, 1);
        }
        _assertSolvent();
    }

    function test_relayOwnerAndOperatorSignaturesAndReplayProtection() public {
        _deposit(A, imd, 500 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sig(ALICE_KEY, _purchaseDigest(A, imd, 200 ether, alice, deadline));
        vm.prank(carol);
        vault.buyWithSig(A, ITEM, imd, 200 ether, alice, deadline, signature);
        assertEq(_available(A, imd), 300 ether);
        assertEq(vault.purchaseNonces(A), 1);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, ITEM, imd, 200 ether, alice, deadline, signature);
        signature = _sig(OP_KEY, _purchaseDigest(A, imd, 100 ether, op, deadline));
        vault.buyWithSig(A, ITEM, imd, 100 ether, op, deadline, signature);
        assertEq(vault.spentInLast24Hours(A, imd), 100 ether);
        signature = _sig(OP_KEY, _purchaseDigest(A, imd, 2, op, deadline));
        vm.expectRevert(NightshiftVault.CapExceeded.selector);
        vault.buyWithSig(A, ITEM, imd, 2, op, deadline, signature);
        assertEq(vault.purchaseNonces(A), 2);
        _assertSolvent();
    }

    function test_purchaseSignatureCannotChangeItemAmountOrAssetAndCanBeCancelled() public {
        _deposit(A, imd, 500 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sig(ALICE_KEY, _purchaseDigest(A, imd, 20 ether, alice, deadline));
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, "other item", imd, 20 ether, alice, deadline, signature);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, ITEM, imd, 40 ether, alice, deadline, signature);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, ITEM, shift, 20 ether, alice, deadline, signature);
        vm.prank(alice);
        vault.invalidatePurchaseNonce(A, 10);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, ITEM, imd, 20 ether, alice, deadline, signature);
        signature = _sig(ALICE_KEY, _purchaseDigest(A, imd, 20 ether, alice, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(NightshiftVault.DeadlineExpired.selector);
        vault.buyWithSig(A, ITEM, imd, 20 ether, alice, deadline, signature);
    }

    function test_ownerChangeInvalidatesOperatorPurchaseSignature() public {
        _deposit(A, imd, 20 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sig(OP_KEY, _purchaseDigest(A, imd, 20 ether, op, deadline));
        bytes memory ownerSignature = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, ownerSignature);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, ITEM, imd, 20 ether, op, deadline, signature);
    }

    function test_purchaseInputAndAuthorityFailuresAndFrozenDirectPayer() public {
        _deposit(A, address(0), 1 ether);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(carol);
        vault.buy(A, ITEM, address(0), 2);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vm.prank(alice);
        vault.buy(A, ITEM, address(0), 3);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.buyDirect{value: 1}(A, ITEM, address(0), 2);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.buyDirect{value: 1}(A, ITEM, imd, 2);
        vm.prank(alice);
        vault.setFrozen(A, true);
        vm.expectRevert(NightshiftVault.AccountFrozen.selector);
        vm.prank(alice);
        vault.buy(A, ITEM, address(0), 2);
        vm.expectRevert(NightshiftVault.AccountFrozen.selector);
        vm.prank(op);
        vault.buy(A, ITEM, address(0), 2);
        _direct(A, address(0), 2);
        assertEq(_available(A, address(0)), 1 ether);
    }

    function test_failedPurchaseRecipientTransferRollsBackEverything() public {
        _deposit(A, imd, 20 ether);
        MockToken(imd).setFailure(true);
        vm.expectRevert();
        vm.prank(op);
        vault.buy(A, ITEM, imd, 20 ether);
        assertEq(_available(A, imd), 20 ether);
        assertEq(vault.pot(imd), 0);
        assertEq(vault.spentInLast24Hours(A, imd), 0);
        _assertSolvent();
    }

    function test_reserveBurnUsesExactPoolPaysETHAndBurnsAllSHIFT() public {
        _deposit(A, address(0), 4 ether);
        _deposit(A, shift, 100 ether);
        _direct(A, address(0), 2 ether);
        MockV4PoolManager manager = MockV4PoolManager(vault.POOL_MANAGER());
        manager.configure(50 ether, false, false);
        MockToken(shift).mint(address(manager), 50 ether);
        vm.prank(keeper);
        assertEq(vault.burnReserve(1 ether, 50 ether), 50 ether);
        assertEq(vault.burnReserve(), 0);
        assertEq(vault.pot(address(0)), 1 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(_balance(vault.DEAD(), shift), 50 ether);
        assertEq(_available(A, shift), 100 ether);
        assertEq(_available(A, address(0)), 4 ether);
        _assertSolvent();
    }

    function test_burnSlippagePartialFillAndEmptyOutputRevertAtomically() public {
        _direct(A, address(0), 2 ether);
        MockV4PoolManager manager = MockV4PoolManager(vault.POOL_MANAGER());
        MockToken(shift).mint(address(manager), 100 ether);
        manager.configure(10 ether, false, false);
        vm.expectRevert(NightshiftVault.SlippageExceeded.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 11 ether);
        manager.configure(10 ether, true, false);
        vm.expectRevert(NightshiftVault.InvalidSwap.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 1);
        manager.configure(10 ether, false, true);
        vm.expectRevert(NightshiftVault.InvalidSwap.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 1);
        assertEq(vault.burnReserve(), 1 ether);
        assertEq(_balance(vault.DEAD(), shift), 0);
        assertEq(address(manager).balance, 0);
        _assertSolvent();
    }

    function test_burnOnlyKeeperReserveLimitsAndCallbackAuthentication() public {
        _deposit(A, address(0), 5 ether);
        _direct(A, address(0), 2 ether);
        vm.prank(vault.OWNER());
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.burnReserve(1 ether, 1);
        vm.startPrank(keeper);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.burnReserve(1 ether, 0);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.burnReserve(1 ether + 1, 1);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.burnReserve(0, 1);
        vm.stopPrank();
        vm.expectRevert(NightshiftVault.InvalidCallback.selector);
        vault.unlockCallback(abi.encode(1 ether, 1));
        vm.prank(vault.POOL_MANAGER());
        vm.expectRevert(NightshiftVault.InvalidCallback.selector);
        vault.unlockCallback(abi.encode(1 ether, 1));
        _assertSolvent();
    }

    function test_burnMustCallbackOnceAndTransferOutput() public {
        _direct(A, address(0), 2 ether);
        MockV4PoolManager manager = MockV4PoolManager(vault.POOL_MANAGER());
        manager.configure(10 ether, false, false);
        MockToken(shift).mint(address(manager), 10 ether);
        manager.setFailures(true, false, false);
        vm.expectRevert(NightshiftVault.InvalidCallback.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 1);
        manager.setFailures(false, true, false);
        vm.expectRevert(NightshiftVault.InvalidCallback.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 1);
        manager.setFailures(false, false, true);
        vm.expectRevert();
        vm.prank(keeper);
        vault.burnReserve(1 ether, 1);
        assertEq(vault.burnReserve(), 1 ether);
        _assertSolvent();
    }

    function test_burnStillWorksPaused() public {
        _direct(A, address(0), 2 ether);
        MockV4PoolManager manager = MockV4PoolManager(vault.POOL_MANAGER());
        manager.configure(10 ether, false, false);
        MockToken(shift).mint(address(manager), 10 ether);
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 10 ether);
        _assertSolvent();
    }

    function testFuzz_exactPurchaseHalves(uint96 rawAmount, uint8 assetIndex, bool direct) public {
        address asset = assets[assetIndex % 3];
        uint256 amount = bound(rawAmount, 1, 1000 ether) * 2;
        if (direct) {
            _direct(A, asset, amount);
        } else {
            _deposit(A, asset, amount);
            vm.prank(alice);
            vault.buy(A, ITEM, asset, amount);
        }
        assertEq(vault.pot(asset), amount / 2);
        if (asset == address(0)) assertEq(vault.burnReserve(), amount / 2);
        else assertEq(_balance(asset == imd ? vault.IMD_BURN_EXECUTOR() : vault.DEAD(), asset), amount / 2);
        _assertSolvent();
    }
}
