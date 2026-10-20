// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken, TestWallet} from "./mocks/MockAssets.sol";

contract AccountsTest is VaultTestBase {
    function test_registrationRequiresBothSignaturesAndCannotReplay() public {
        bytes32 id = keccak256("new");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = _registrationDigest(id, alice, deadline);
        bytes memory ownSig = _sig(ALICE_KEY, digest);
        bytes memory operatorSig = _sig(OP_KEY, digest);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, alice, deadline, "", operatorSig);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, alice, deadline, ownSig, "");
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, bob, deadline, ownSig, operatorSig);
        vault.register(id, alice, deadline, ownSig, operatorSig);
        assertEq(vault.accountOf(id), alice);
        vm.expectRevert(NightshiftVault.AlreadyRegistered.selector);
        vault.register(id, alice, deadline, ownSig, operatorSig);
    }

    function test_registrationExpiryDomainAndInputValidation() public {
        bytes32 id = keccak256("new");
        uint256 deadline = vm.getBlockTimestamp();
        bytes32 digest = _registrationDigest(id, alice, deadline);
        bytes memory ownerSig = _sig(ALICE_KEY, digest);
        bytes memory operatorSig = _sig(OP_KEY, digest);
        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, alice, deadline, ownerSig, operatorSig);
        vm.chainId(originalChainId);
        NightshiftVault other = new NightshiftVault();
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        other.register(id, alice, deadline, ownerSig, operatorSig);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(NightshiftVault.DeadlineExpired.selector);
        vault.register(id, alice, deadline, ownerSig, operatorSig);
        vm.expectRevert(NightshiftVault.InvalidAddress.selector);
        vault.register(id, address(0), vm.getBlockTimestamp(), "", "");
        vm.expectRevert(NightshiftVault.InvalidAccount.selector);
        vault.register(bytes32(0), alice, vm.getBlockTimestamp(), "", "");
    }

    function test_registrationAcceptsERC1271OwnerAndOperator() public {
        TestWallet operatorWallet = new TestWallet(op);
        vm.prank(vault.OWNER());
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, address(operatorWallet));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        TestWallet wallet = new TestWallet(alice);
        _register(keccak256("contract wallet"), address(wallet), ALICE_KEY);
        assertEq(vault.accountOf(keccak256("contract wallet")), address(wallet));
    }

    function test_onlyOwnerCanChangeOwnerWithNewOwnersSignatureAndNonce() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(vault.OWNER());
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.setOwner(A, carol, deadline, signature);
        bytes memory wrong = _sig(BOB_KEY, _ownerDigest(A, carol, deadline));
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, wrong);
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, signature);
        assertEq(vault.accountOf(A), carol);
        assertEq(vault.ownerNonces(A), 1);
        bytes memory back = _sig(ALICE_KEY, _ownerDigest(A, alice, deadline));
        vm.prank(carol);
        vault.setOwner(A, alice, deadline, back);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, signature);
    }

    function test_depositSweepAndWithdrawAllAssets() public {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            uint256 amount = 2 ether;
            address forwarder = vault.depositAddress(A);
            if (i == 0) {
                assertEq(forwarder.code.length, 0);
                (bool ok,) = forwarder.call{value: amount}("");
                assertTrue(ok);
            } else {
                MockToken(asset).mint(forwarder, amount);
            }
            vm.prank(carol);
            assertEq(vault.sweep(A, asset), amount);
            assertGt(forwarder.code.length, 0);
            assertEq(DepositForwarder(payable(forwarder)).vault(), address(vault));
            assertEq(DepositForwarder(payable(forwarder)).accountId(), A);
            assertEq(_available(A, asset), amount);
            assertEq(_balance(forwarder, asset), 0);
            assertEq(vault.sweep(A, asset), 0);
            _deposit(A, asset, amount);
            uint256 beforeBalance = _balance(alice, asset);
            vm.prank(alice);
            vault.withdraw(A, asset, amount * 2);
            assertEq(_balance(alice, asset), beforeBalance + amount * 2);
            _assertSolvent();
        }
    }

    function test_counterfactualTokenDepositAndCrossAccountIsolation() public {
        address forwarderA = vault.depositAddress(A);
        address forwarderB = vault.depositAddress(B);
        assertTrue(forwarderA != forwarderB);
        MockToken(imd).mint(forwarderA, 123);
        assertEq(forwarderA.code.length, 0);
        vault.sweep(B, imd);
        assertEq(_available(B, imd), 0);
        vault.sweep(A, imd);
        assertEq(_available(A, imd), 123);
        vm.expectRevert(DepositForwarder.OnlyVault.selector);
        DepositForwarder(payable(forwarderA)).sweep(imd);
        vm.expectRevert(NightshiftVault.UnsupportedAsset.selector);
        vault.sweep(A, address(123));
        vm.expectRevert(NightshiftVault.InvalidAccount.selector);
        vault.sweep(keccak256("unregistered"), imd);
        _assertSolvent();
    }

    function test_withdrawOnlyOwnerWhilePausedAndFrozenAllAssets() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(A, assets[i], 1 ether);
        }
        vm.prank(alice);
        vault.setFrozen(A, true);
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            vm.expectRevert(NightshiftVault.Unauthorized.selector);
            vm.prank(op);
            vault.withdraw(A, asset, 1);
            vm.prank(vault.OWNER());
            vm.expectRevert(NightshiftVault.Unauthorized.selector);
            vault.withdraw(A, asset, 1);
            vm.prank(alice);
            vault.withdraw(A, asset, 1 ether);
            assertEq(_available(A, asset), 0);
        }
        _assertSolvent();
    }

    function test_ownerChangeRedirectsOnlyToConsentingNewOwner() public {
        _deposit(A, imd, 12 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, signature);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(alice);
        vault.withdraw(A, imd, 1);
        vm.prank(carol);
        vault.withdraw(A, imd, 12 ether);
        assertEq(IERC20(imd).balanceOf(carol), 12 ether);
    }

    function test_unsupportedAssetZeroAmountsUnknownAccountsAndUnlabelledETH() public {
        vm.expectRevert(NightshiftVault.UnsupportedAsset.selector);
        vault.deposit(A, address(123), 1);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.deposit(A, address(0), 1);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.depositETH(A);
        vm.expectRevert(NightshiftVault.InvalidAccount.selector);
        vault.depositETH{value: 1}(bytes32(uint256(999)));
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
        vm.expectRevert(NightshiftVault.InsufficientBalance.selector);
        vm.prank(alice);
        vault.withdraw(A, imd, 1);
    }

    function test_falseReturningAndFeeTokensCannotInflateBalances() public {
        MockToken(imd).mint(address(this), 100);
        IERC20(imd).approve(address(vault), 100);
        MockToken(imd).setFailure(true);
        vm.expectRevert();
        vault.deposit(A, imd, 100);
        assertEq(_available(A, imd), 0);
        MockToken(imd).setFailure(false);
        MockToken(imd).setFee(true);
        vm.expectRevert(NightshiftVault.TransferAmountMismatch.selector);
        vault.deposit(A, imd, 100);
        assertEq(_available(A, imd), 0);
        address forwarder = vault.depositAddress(A);
        MockToken(imd).mint(forwarder, 100);
        vm.expectRevert(NightshiftVault.TransferAmountMismatch.selector);
        vault.sweep(A, imd);
        assertEq(_available(A, imd), 0);
        assertEq(IERC20(imd).balanceOf(forwarder), 100);
    }

    function test_reentrantAndRejectingOwnerCannotDrainOrLoseWithdrawal() public {
        TestWallet wallet = new TestWallet(alice);
        bytes32 id = keccak256("reentry wallet");
        _register(id, address(wallet), ALICE_KEY);
        _deposit(id, address(0), 1 ether);
        wallet.configure(vault, id, true, false);
        vm.prank(alice);
        wallet.execute(address(vault), abi.encodeCall(vault.withdraw, (id, address(0), 0.5 ether)));
        assertFalse(wallet.reentrySucceeded());
        assertEq(_available(id, address(0)), 0.5 ether);
        wallet.configure(vault, id, false, true);
        vm.expectRevert(NightshiftVault.ETHTransferFailed.selector);
        vm.prank(alice);
        wallet.execute(address(vault), abi.encodeCall(vault.withdraw, (id, address(0), 0.5 ether)));
        assertEq(_available(id, address(0)), 0.5 ether);
    }

    function test_tokenCallbackCannotReenterDeposit() public {
        MockToken(imd).setCallback(address(vault), abi.encodeCall(vault.sweep, (A, imd)));
        _deposit(A, imd, 100);
        assertEq(_available(A, imd), 100);
        _assertSolvent();
    }
}
