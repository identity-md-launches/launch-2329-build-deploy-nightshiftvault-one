// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {MockToken, RejectETH} from "./mocks/MockAssets.sol";

contract GamesAndCapsTest is VaultTestBase {
    function test_gameResultsAndFivePercentFeeAllAssets() public {
        for (uint256 a; a < 3; ++a) {
            address asset = assets[a];
            (, uint256 stake) = vault.caps(A, asset);
            for (uint8 result; result < 3; ++result) {
                bytes32 id = keccak256(abi.encode(a, result));
                _deposit(A, asset, stake);
                _deposit(B, asset, stake);
                uint256 availableA = _available(A, asset);
                uint256 availableB = _available(B, asset);
                uint256 feeBefore = _balance(vault.FEE_SPLITTER(), asset);
                _lock(id, asset, stake);
                assertEq(_locked(A, asset), stake);
                assertEq(_locked(B, asset), stake);
                _settle(id, result);
                uint256 fee = result == 2 ? 0 : 2 * stake / 20;
                assertEq(
                    _available(A, asset), availableA - stake + (result == 0 ? 2 * stake - fee : result == 2 ? stake : 0)
                );
                assertEq(
                    _available(B, asset), availableB - stake + (result == 1 ? 2 * stake - fee : result == 2 ? stake : 0)
                );
                assertEq(_locked(A, asset), 0);
                assertEq(_locked(B, asset), 0);
                assertEq(_balance(vault.FEE_SPLITTER(), asset), feeBefore + fee);
                _assertSolvent();
            }
        }
    }

    function test_lockRejectsUnauthorizedDuplicateSameOwnerInvalidStakeAndExpiry() public {
        _deposit(A, address(0), 1 ether);
        _deposit(B, address(0), 1 ether);
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.lockGame("game", A, B, address(0), 1, expiry);
        vm.startPrank(op);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.lockGame("game", A, A, address(0), 1, expiry);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.lockGame("game", A, B, address(0), 0, expiry);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.lockGame("game", A, B, address(0), 1, vm.getBlockTimestamp());
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.lockGame("game", A, B, address(0), 1, vm.getBlockTimestamp() + 24 hours + 1);
        vm.expectRevert(NightshiftVault.InvalidAccount.selector);
        vault.lockGame("game", A, "unknown", address(0), 1, expiry);
        vault.lockGame("game", A, B, address(0), 1, expiry);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.lockGame("game", A, B, address(0), 1, expiry);
        vm.stopPrank();
        _register("also alice", alice, ALICE_KEY);
        vm.prank(op);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.lockGame("same owner", A, "also alice", address(0), 1, expiry);
        _settle("game", 2);
        vm.prank(op);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.lockGame("game", A, B, address(0), 1, expiry);
    }

    function test_wrongSignerExpiredSignatureWrongDomainInvalidResultAndDoubleSettlement() public {
        _deposit(A, address(0), 1 ether);
        _deposit(B, address(0), 1 ether);
        _lock("game", address(0), 0.01 ether);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory wrong = _resultSig("game", 0, deadline, ALICE_KEY);
        bytes memory right = _resultSig("game", 0, deadline, RESULT_KEY);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.settle("game", 0, deadline, wrong);
        vm.expectRevert(NightshiftVault.InvalidResult.selector);
        vault.settle("game", 3, deadline, right);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.settle("game", 1, deadline, right);
        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.settle("game", 0, deadline, right);
        vm.chainId(originalChainId);
        vm.warp(deadline + 1);
        vm.expectRevert(NightshiftVault.DeadlineExpired.selector);
        vault.settle("game", 0, deadline, right);
        _settle("game", 0);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.settle("game", 0, deadline, right);
        vm.expectRevert(NightshiftVault.InvalidGame.selector);
        vault.refundGame("game");
        _assertSolvent();
    }

    function test_refundBoundaryAndSettlementCutoffAllAssets() public {
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 3; ++i) {
            _deposit(A, assets[i], 100);
            _deposit(B, assets[i], 100);
            _lock(bytes32(i + 1), assets[i], 100);
        }
        vm.warp(start + 25 hours - 1);
        vm.expectRevert(NightshiftVault.TooEarly.selector);
        vault.refundGame(bytes32(uint256(1)));
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        vm.prank(alice);
        vault.setFrozen(A, true);
        vm.warp(start + 25 hours);
        for (uint256 i; i < 3; ++i) {
            bytes32 id = bytes32(i + 1);
            bytes memory signature = _resultSig(id, 0, vm.getBlockTimestamp(), RESULT_KEY);
            vm.expectRevert(NightshiftVault.InvalidGame.selector);
            vault.settle(id, 0, vm.getBlockTimestamp(), signature);
            vm.prank(carol);
            vault.refundGame(id);
            assertEq(_available(A, assets[i]), 100);
            assertEq(_available(B, assets[i]), 100);
            assertEq(_locked(A, assets[i]), 0);
            vm.expectRevert(NightshiftVault.InvalidGame.selector);
            vault.refundGame(id);
        }
        _assertSolvent();
    }

    function test_settleWorksPausedAndFrozen() public {
        _deposit(A, imd, 10 ether);
        _deposit(B, imd, 10 ether);
        _lock("game", imd, 10 ether);
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        vm.prank(alice);
        vault.setFrozen(A, true);
        _settle("game", 1);
        assertEq(_available(B, imd), 19 ether);
        _assertSolvent();
    }

    function test_feeFailureRollsBackSettlementAndRefundRemainsAvailable() public {
        _deposit(A, address(0), 0.01 ether);
        _deposit(B, address(0), 0.01 ether);
        _lock("game", address(0), 0.01 ether);
        RejectETH rejecting = new RejectETH();
        vm.etch(vault.FEE_SPLITTER(), address(rejecting).code);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _resultSig("game", 0, deadline, RESULT_KEY);
        vm.expectRevert(NightshiftVault.ETHTransferFailed.selector);
        vault.settle("game", 0, deadline, signature);
        assertEq(_locked(A, address(0)), 0.01 ether);
        assertEq(_available(A, address(0)), 0);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        vault.refundGame("game");
        assertEq(_available(A, address(0)), 0.01 ether);
        _assertSolvent();
    }

    function test_dailyAndPerGameCapsAllAssets() public {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            (uint256 daily, uint256 perGame) = vault.caps(A, asset);
            assertEq(perGame, daily / 5);
            _deposit(A, asset, daily * 2);
            _deposit(B, asset, daily * 2);
            vm.expectRevert(NightshiftVault.CapExceeded.selector);
            _lock(keccak256(abi.encode(i, "too large")), asset, perGame + 1);
            for (uint256 j; j < 5; ++j) {
                bytes32 id = keccak256(abi.encode(i, j));
                _lock(id, asset, perGame);
                _settle(id, 2);
            }
            assertEq(vault.spentInLast24Hours(A, asset), daily);
            vm.expectRevert(NightshiftVault.CapExceeded.selector);
            _lock(keccak256(abi.encode(i, "exhausted")), asset, 1);
        }
        _assertSolvent();
    }

    function test_exactRollingWindowDoesNotResetAtMidnightOrFirstSpendAnniversary() public {
        _deposit(A, address(0), 1 ether);
        _deposit(B, address(0), 1 ether);
        uint256 start = vm.getBlockTimestamp();
        _lock("one", address(0), 0.01 ether);
        vm.warp(start + 23 hours);
        for (uint256 i; i < 4; ++i) {
            _lock(bytes32(i + 2), address(0), 0.01 ether);
        }
        vm.warp(start + 24 hours - 1);
        vm.expectRevert(NightshiftVault.CapExceeded.selector);
        _lock("too early", address(0), 1);
        vm.warp(start + 24 hours);
        assertEq(vault.spentInLast24Hours(A, address(0)), 0.04 ether);
        _lock("now", address(0), 0.01 ether);
        vm.expectRevert(NightshiftVault.CapExceeded.selector);
        _lock("still capped", address(0), 1);
        vm.warp(start + 47 hours);
        assertEq(vault.spentInLast24Hours(A, address(0)), 0.01 ether);
        _assertSolvent();
    }

    function test_capChangesLowerImmediatelyRaiseAfterDelayReplaceAndMixedChange() public {
        uint256 start = vm.getBlockTimestamp();
        vm.prank(alice);
        vault.setCaps(A, imd, 40 ether, 5 ether);
        (uint256 daily, uint256 game) = vault.caps(A, imd);
        assertEq(daily, 40 ether);
        assertEq(game, 5 ether);
        vm.prank(alice);
        vault.setCaps(A, imd, 80 ether, 3 ether);
        (daily, game) = vault.caps(A, imd);
        assertEq(daily, 40 ether);
        assertEq(game, 3 ether);
        vm.warp(start + 24 hours - 1);
        (daily,) = vault.caps(A, imd);
        assertEq(daily, 40 ether);
        vm.warp(start + 24 hours);
        (daily, game) = vault.caps(A, imd);
        assertEq(daily, 80 ether);
        assertEq(game, 3 ether);
        vm.prank(alice);
        vault.setCaps(A, imd, 90 ether, 9 ether);
        vm.warp(start + 25 hours);
        vm.prank(alice);
        vault.setCaps(A, imd, 0, 0);
        vm.warp(start + 49 hours);
        (daily, game) = vault.caps(A, imd);
        assertEq(daily, 0);
        assertEq(game, 0);
        vm.prank(vault.OWNER());
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.setCaps(A, imd, 100 ether, 100 ether);
    }

    function test_loweringCapsBelowExistingSpendDoesNotUnderflowOrEraseHistory() public {
        _deposit(A, imd, 100 ether);
        _deposit(B, imd, 100 ether);
        _lock("game", imd, 20 ether);
        vm.prank(alice);
        vault.setCaps(A, imd, 10 ether, 5 ether);
        vm.expectRevert(NightshiftVault.CapExceeded.selector);
        _lock("blocked", imd, 1);
        assertEq(vault.spentInLast24Hours(A, imd), 20 ether);
        _settle("game", 2);
        assertEq(vault.spentInLast24Hours(A, imd), 20 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _lock("after window", imd, 5 ether);
    }

    function test_freezeImmediateUnfreezeDelayAndRefreezeCancel() public {
        _deposit(A, imd, 100 ether);
        _deposit(B, imd, 100 ether);
        uint256 start = vm.getBlockTimestamp();
        vm.prank(alice);
        vault.setFrozen(A, true);
        vm.expectRevert(NightshiftVault.AccountFrozen.selector);
        _lock("game", imd, 1);
        vm.prank(alice);
        vault.setFrozen(A, false);
        vm.warp(start + 24 hours - 1);
        assertTrue(vault.frozen(A));
        vm.warp(start + 24 hours);
        assertFalse(vault.frozen(A));
        _lock("game", imd, 1);
        vm.startPrank(alice);
        vault.setFrozen(A, true);
        vault.setFrozen(A, false);
        vault.setFrozen(A, true);
        vm.stopPrank();
        vm.warp(start + 3 days);
        assertTrue(vault.frozen(A));
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(op);
        vault.setFrozen(A, false);
    }

    function test_ownerChangePreservesSpendAndCancelsPendingRelaxation() public {
        _deposit(A, imd, 100 ether);
        _deposit(B, imd, 100 ether);
        _lock("game", imd, 20 ether);
        vm.startPrank(alice);
        vault.setCaps(A, imd, 1000 ether, 1000 ether);
        vault.setFrozen(A, true);
        vault.setFrozen(A, false);
        vm.stopPrank();
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, sig);
        assertEq(vault.spentInLast24Hours(A, imd), 20 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertTrue(vault.frozen(A));
        (uint256 daily, uint256 game) = vault.caps(A, imd);
        assertEq(daily, 100 ether);
        assertEq(game, 20 ether);
        _settle("game", 0);
        uint256 available = _available(A, imd);
        vm.prank(carol);
        vault.withdraw(A, imd, available);
    }

    function testFuzz_feeConservesEveryWei(uint96 rawStake, uint8 assetIndex, bool bWins) public {
        address asset = assets[assetIndex % 3];
        (, uint256 cap) = vault.caps(A, asset);
        uint256 stake = bound(rawStake, 1, cap);
        _deposit(A, asset, stake);
        _deposit(B, asset, stake);
        _lock("fuzz", asset, stake);
        _settle("fuzz", bWins ? 1 : 0);
        uint256 fee = (2 * stake) / 20;
        assertEq(_available(bWins ? B : A, asset), 2 * stake - fee);
        assertEq(_balance(vault.FEE_SPLITTER(), asset), fee);
        assertEq(_balance(address(vault), asset) + fee, 2 * stake);
        _assertSolvent();
    }

    function testFuzz_rollingWindowMatchesIndependentHistory(uint32[12] memory intervals, uint64[12] memory amounts)
        public
    {
        _deposit(A, imd, 10_000 ether);
        _deposit(B, imd, 10_000 ether);
        vm.prank(alice);
        vault.setCaps(A, imd, 10_000 ether, 1000 ether);
        vm.prank(bob);
        vault.setCaps(B, imd, 10_000 ether, 1000 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256[12] memory timestamps;
        uint256[12] memory stakes;
        for (uint256 i; i < 12; ++i) {
            vm.warp(vm.getBlockTimestamp() + intervals[i] % (48 hours));
            timestamps[i] = vm.getBlockTimestamp();
            stakes[i] = uint256(amounts[i]) + 1;
            _lock(bytes32(i + 1), imd, stakes[i]);
            uint256 expected;
            for (uint256 j; j <= i; ++j) {
                if (timestamps[j] > vm.getBlockTimestamp() - 24 hours) expected += stakes[j];
            }
            assertEq(vault.spentInLast24Hours(A, imd), expected);
            assertEq(vault.spentInLast24Hours(B, imd), expected);
        }
        _assertSolvent();
    }
}
