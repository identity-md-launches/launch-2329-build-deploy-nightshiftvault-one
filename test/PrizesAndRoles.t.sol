// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";

contract PrizesAndRolesTest is VaultTestBase {
    function test_postsClaimsAndExpiresOnlyUnclaimedAllAssets() public {
        uint256 postedAt = vm.getBlockTimestamp();
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            _direct(A, asset, 200 ether);
            bytes32 leafA = _leaf(1, A, asset, 30 ether);
            bytes32 leafB = _leaf(1, B, asset, 50 ether);
            bytes32 root = _pair(leafA, leafB);
            vm.prank(op);
            vault.postPrizes(1, root, asset, 80 ether);
            assertEq(vault.pot(asset), 20 ether);
            assertEq(vault.reservedPrizes(asset), 80 ether);
            bytes32[] memory proof = new bytes32[](1);
            proof[0] = leafB;
            vm.prank(carol);
            vault.claimPrize(1, A, asset, 30 ether, proof);
            assertEq(_available(A, asset), 30 ether);
            assertEq(vault.reservedPrizes(asset), 50 ether);
            vm.expectRevert(NightshiftVault.AlreadyClaimed.selector);
            vault.claimPrize(1, A, asset, 30 ether, proof);
            vm.expectRevert(NightshiftVault.InvalidEpoch.selector);
            vm.prank(op);
            vault.postPrizes(1, root, asset, 1);
            vm.expectRevert(NightshiftVault.TooEarly.selector);
            vault.expirePrizes(1, asset);
            _assertSolvent();
        }
        vm.warp(postedAt + 30 days);
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            bytes32[] memory proof = new bytes32[](1);
            proof[0] = _leaf(1, A, asset, 30 ether);
            vm.expectRevert(NightshiftVault.InvalidEpoch.selector);
            vault.claimPrize(1, B, asset, 50 ether, proof);
            vault.expirePrizes(1, asset);
            assertEq(vault.pot(asset), 70 ether);
            assertEq(vault.reservedPrizes(asset), 0);
            vm.expectRevert(NightshiftVault.InvalidEpoch.selector);
            vault.expirePrizes(1, asset);
            vm.expectRevert(NightshiftVault.InvalidEpoch.selector);
            vm.prank(op);
            vault.postPrizes(1, bytes32(uint256(1)), asset, 1);
        }
        _assertSolvent();
    }

    function test_prizePostingCannotReservePlayerMoneyBurnReserveOrOtherAsset() public {
        _deposit(A, address(0), 100 ether);
        _deposit(A, imd, 100 ether);
        _direct(A, address(0), 2 ether);
        bytes32 root = _leaf(1, A, address(0), 2 ether);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vm.prank(op);
        vault.postPrizes(1, root, address(0), 2 ether);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vm.prank(op);
        vault.postPrizes(1, root, imd, 1);
        vm.prank(vault.OWNER());
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.postPrizes(1, root, address(0), 1);
        vm.expectRevert(NightshiftVault.InvalidEpoch.selector);
        vm.prank(op);
        vault.postPrizes(1, bytes32(0), address(0), 1);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vm.prank(op);
        vault.postPrizes(1, root, address(0), 0);
        vm.prank(op);
        vault.postPrizes(1, root, address(0), 1 ether);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vm.prank(op);
        vault.postPrizes(2, root, address(0), 1);
        _assertSolvent();
    }

    function test_badProofsAndRootTotalsAreBoundedByReservation() public {
        _direct(A, imd, 202 ether);
        _direct(A, shift, 200 ether);
        bytes32 leafA = _leaf(1, A, imd, 60 ether);
        bytes32 leafB = _leaf(1, B, imd, 60 ether);
        bytes32 root = _pair(leafA, leafB);
        vm.startPrank(op);
        vault.postPrizes(1, root, imd, 100 ether);
        vault.postPrizes(2, root, imd, 1 ether);
        vault.postPrizes(1, root, shift, 100 ether);
        vm.stopPrank();
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        vm.expectRevert(NightshiftVault.InvalidProof.selector);
        vault.claimPrize(1, C, imd, 60 ether, proof);
        vm.expectRevert(NightshiftVault.InvalidProof.selector);
        vault.claimPrize(1, A, imd, 59 ether, proof);
        vm.expectRevert(NightshiftVault.InvalidProof.selector);
        vault.claimPrize(1, A, shift, 60 ether, proof);
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.claimPrize(2, A, imd, 60 ether, proof);
        vm.expectRevert(NightshiftVault.InvalidProof.selector);
        vault.claimPrize(1, A, imd, 60 ether, new bytes32[](0));
        vault.claimPrize(1, A, imd, 60 ether, proof);
        proof[0] = leafA;
        vm.expectRevert(NightshiftVault.InvalidAmount.selector);
        vault.claimPrize(1, B, imd, 60 ether, proof);
        assertEq(vault.reservedPrizes(imd), 41 ether);
        _assertSolvent();
    }

    function test_claimsWhilePausedFrozenAndOwnerChanged() public {
        _direct(A, address(0), 2 ether);
        vm.prank(op);
        vault.postPrizes(0, _leaf(0, A, address(0), 1 ether), address(0), 1 ether);
        uint256 deadline = vm.getBlockTimestamp();
        bytes memory sig = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, sig);
        vm.prank(carol);
        vault.setFrozen(A, true);
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        vault.claimPrize(0, A, address(0), 1 ether, new bytes32[](0));
        vm.prank(carol);
        vault.withdraw(A, address(0), 1 ether);
        assertEq(carol.balance, 1 ether);
        _assertSolvent();
    }

    function test_lastSecondClaimAndFullyClaimedExpiry() public {
        _direct(A, imd, 2 ether);
        vm.prank(op);
        vault.postPrizes(1, _leaf(1, A, imd, 1 ether), imd, 1 ether);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 days - 1);
        vault.claimPrize(1, A, imd, 1 ether, new bytes32[](0));
        vm.warp(start + 30 days);
        vault.expirePrizes(1, imd);
        assertEq(vault.pot(imd), 0);
        assertEq(vault.reservedPrizes(imd), 0);
        _assertSolvent();
    }

    function test_initialRolesAndOwnerAreFixedIndependentOfDeployer() public {
        vm.prank(carol);
        NightshiftVault fresh = new NightshiftVault();
        assertEq(fresh.owner(), vault.OWNER());
        assertEq(fresh.operator(), vault.INITIAL_ROLE());
        assertEq(fresh.resultSigner(), vault.INITIAL_ROLE());
        assertEq(fresh.keeper(), vault.INITIAL_ROLE());
        assertFalse(fresh.paused());
    }

    function test_roleChangesOnlyOwnerAndTakeFull48Hours() public {
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < 3; ++i) {
            NightshiftVault.Role role = NightshiftVault.Role(i);
            vm.expectRevert(NightshiftVault.Unauthorized.selector);
            vm.prank(op);
            vault.scheduleRoleChange(role, carol);
            vm.prank(vault.OWNER());
            vault.scheduleRoleChange(role, carol);
            vm.expectRevert(NightshiftVault.TooEarly.selector);
            vault.applyRoleChange(role);
        }
        vm.warp(start + 48 hours - 1);
        assertEq(vault.operator(), op);
        assertEq(vault.resultSigner(), resultSigner);
        assertEq(vault.keeper(), keeper);
        vm.warp(start + 48 hours);
        assertEq(vault.operator(), carol);
        assertEq(vault.resultSigner(), carol);
        assertEq(vault.keeper(), carol);
        for (uint256 i; i < 3; ++i) {
            vault.applyRoleChange(NightshiftVault.Role(i));
            (address current, address pending, uint256 readyAt) = vault.roleChanges(NightshiftVault.Role(i));
            assertEq(current, carol);
            assertEq(pending, address(0));
            assertEq(readyAt, 0);
        }
    }

    function test_roleReplacementRestartsDelayCancellationAndNonzeroValidation() public {
        uint256 start = vm.getBlockTimestamp();
        vm.startPrank(vault.OWNER());
        vm.expectRevert(NightshiftVault.InvalidAddress.selector);
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, address(0));
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, alice);
        vm.warp(start + 47 hours);
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, bob);
        vm.warp(start + 48 hours);
        assertEq(vault.operator(), op);
        vault.cancelRoleChange(NightshiftVault.Role.Operator);
        vm.warp(start + 96 hours);
        assertEq(vault.operator(), op);
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, alice);
        vm.warp(start + 144 hours);
        vm.expectRevert(NightshiftVault.NoPendingChange.selector);
        vault.cancelRoleChange(NightshiftVault.Role.Operator);
        assertEq(vault.operator(), alice);
        vm.stopPrank();
    }

    function test_resultSignerRotationRejectsFormerSignerForExistingGames() public {
        _deposit(A, imd, 20 ether);
        _deposit(B, imd, 20 ether);
        vm.prank(vault.OWNER());
        vault.scheduleRoleChange(NightshiftVault.Role.ResultSigner, carol);
        vm.warp(vm.getBlockTimestamp() + 47 hours);
        _lock("game", imd, 20 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory oldSig = _resultSig("game", 0, deadline, RESULT_KEY);
        bytes memory newSig = _resultSig("game", 0, deadline, CAROL_KEY);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.settle("game", 0, deadline, oldSig);
        vault.settle("game", 0, deadline, newSig);
    }

    function test_pauseScopeAndOwnerCannotMoveOrRedirectPlayerFunds() public {
        _deposit(A, imd, 20 ether);
        _deposit(B, imd, 20 ether);
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        vm.expectRevert(NightshiftVault.IsPaused.selector);
        vault.depositETH{value: 1}(A);
        vm.expectRevert(NightshiftVault.IsPaused.selector);
        vault.deposit(A, imd, 1);
        vm.expectRevert(NightshiftVault.IsPaused.selector);
        vault.sweep(A, imd);
        vm.expectRevert(NightshiftVault.IsPaused.selector);
        _lock("game", imd, 1);
        vm.expectRevert(NightshiftVault.IsPaused.selector);
        vm.prank(alice);
        vault.buy(A, ITEM, imd, 2);
        vm.expectRevert(NightshiftVault.IsPaused.selector);
        vault.buyDirect{value: 2}(A, ITEM, address(0), 2);
        vm.prank(vault.OWNER());
        vault.setPaused(false);
        vm.startPrank(vault.OWNER());
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.buy(A, ITEM, imd, 2);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.withdraw(A, imd, 1);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.setOwner(A, carol, vm.getBlockTimestamp(), "");
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.setFrozen(A, true);
        (bool ok,) =
            address(vault).call(abi.encodeWithSignature("rescue(address,address,uint256)", imd, carol, 20 ether));
        assertFalse(ok);
        vm.stopPrank();
        _assertSolvent();
    }

    function testFuzz_prizeConservation(uint96 rawTotal, uint96 rawClaim, uint8 assetIndex) public {
        address asset = assets[assetIndex % 3];
        uint256 total = bound(rawTotal, 2, 1000 ether);
        uint256 amount = bound(rawClaim, 1, total - 1);
        _direct(A, asset, total * 2);
        vm.prank(op);
        vault.postPrizes(7, _leaf(7, A, asset, amount), asset, total);
        vault.claimPrize(7, A, asset, amount, new bytes32[](0));
        assertEq(vault.reservedPrizes(asset), total - amount);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vault.expirePrizes(7, asset);
        assertEq(vault.pot(asset), total - amount);
        assertEq(_available(A, asset), amount);
        _assertSolvent();
    }
}
