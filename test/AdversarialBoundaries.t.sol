// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {IV4PoolManager} from "../src/interfaces/IV4PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken, TestWallet} from "./mocks/MockAssets.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";

/// @dev A supported-asset stand-in with legacy empty return data, exercising SafeERC20 paths.
contract EmptyReturnAsset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Regression tests for atomicity, replay boundaries, asset isolation and custody events.
contract AdversarialBoundariesTest is VaultTestBase {
    function test_domainUsesRequiredNameVersionChainAndVault() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NightshiftVault"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.DOMAIN_SEPARATOR(), expected);
        assertEq(vault.REGISTER_TYPEHASH(), keccak256("Register(bytes32 accountId,address owner,uint256 deadline)"));
        assertEq(vault.RESULT_TYPEHASH(), keccak256("Result(bytes32 gameId,uint8 result,uint256 deadline)"));
    }

    function test_registrationAtExactDeadlineAndMalformedSignatureRollback() public {
        bytes32 id = keccak256("registration deadline");
        uint256 deadline = vm.getBlockTimestamp();
        bytes32 digest = _registrationDigest(id, alice, deadline);
        bytes memory ownerSig = _sig(ALICE_KEY, digest);
        bytes memory operatorSig = _sig(OP_KEY, digest);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, alice, deadline, hex"01", operatorSig);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, alice, deadline, ownerSig, hex"01");
        assertEq(vault.accountOf(id), address(0));
        vm.expectEmit(true, true, false, true, address(vault));
        emit NightshiftVault.Registered(id, alice);
        vault.register(id, alice, deadline, ownerSig, operatorSig);
    }

    function test_registrationRejectsMalleableOwnerSignature() public {
        bytes32 id = keccak256("malleable");
        uint256 deadline = vm.getBlockTimestamp();
        bytes32 digest = _registrationDigest(id, alice, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_KEY, digest);
        uint256 order = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(order - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.register(id, alice, deadline, highS, _sig(OP_KEY, digest));
        assertEq(vault.accountOf(id), address(0));
    }

    function test_lockFailureAtSecondPlayerRestoresFirstPlayerBalanceAndCapAllAssets() public {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            _deposit(A, asset, 100);
            bytes32 id = keccak256(abi.encode("atomic lock", i));
            // A passes cap consumption and debiting; B has no funds.
            vm.expectRevert(NightshiftVault.InsufficientBalance.selector);
            _lock(id, asset, 100);
            _assertFailedLock(id, asset, 100);
            _deposit(B, asset, 100);
            vm.prank(bob);
            vault.setCaps(B, asset, 0, 0);
            vm.expectRevert(NightshiftVault.CapExceeded.selector);
            _lock(id, asset, 100);
            _assertFailedLock(id, asset, 100);
            // The failed attempt must not consume the ID either.
            vm.prank(bob);
            vault.setCaps(B, asset, 100, 100);
            vm.warp(vm.getBlockTimestamp() + 24 hours);
            _lock(id, asset, 100);
            _settle(id, 2);
            _assertSolvent();
        }
    }

    function _assertFailedLock(bytes32 id, address asset, uint256 available) private view {
        assertEq(_available(A, asset), available);
        assertEq(_locked(A, asset), 0);
        assertEq(_locked(B, asset), 0);
        assertEq(vault.spentInLast24Hours(A, asset), 0);
        assertEq(vault.spentInLast24Hours(B, asset), 0);
        (,,,,, NightshiftVault.GameStatus status,) = vault.games(id);
        assertEq(uint256(status), uint256(NightshiftVault.GameStatus.None));
    }

    function test_failedTokenFeeTransferRestoresGameAndCanRetry() public {
        for (uint256 i = 1; i < 3; ++i) {
            address asset = assets[i];
            bytes32 id = bytes32(i);
            _deposit(A, asset, 100);
            _deposit(B, asset, 100);
            _lock(id, asset, 100);
            bytes memory sig = _resultSig(id, 1, vm.getBlockTimestamp(), RESULT_KEY);
            MockToken(asset).setFailure(true);
            vm.expectRevert();
            vault.settle(id, 1, vm.getBlockTimestamp(), sig);
            assertEq(_locked(A, asset), 100);
            assertEq(_locked(B, asset), 100);
            assertEq(_available(B, asset), 0);
            assertEq(vault.totalPlayerFunds(asset), 200);
            (,,,,, NightshiftVault.GameStatus status,) = vault.games(id);
            assertEq(uint256(status), uint256(NightshiftVault.GameStatus.Locked));
            MockToken(asset).setFailure(false);
            vault.settle(id, 1, vm.getBlockTimestamp(), sig);
            assertEq(_available(B, asset), 190);
            assertEq(_balance(vault.FEE_SPLITTER(), asset), 10);
        }
        _assertSolvent();
    }

    function test_failedRelayedPurchaseKeepsNonceCapAndFundsThenSameSignatureWorks() public {
        for (uint256 i = 1; i < 3; ++i) {
            address asset = assets[i];
            _deposit(A, asset, 100);
            uint256 nonceBefore = vault.purchaseNonces(A);
            bytes memory sig = _sig(OP_KEY, _purchaseDigest(A, asset, 100, op, vm.getBlockTimestamp()));
            MockToken(asset).setFailure(true);
            vm.expectRevert();
            vault.buyWithSig(A, ITEM, asset, 100, op, vm.getBlockTimestamp(), sig);
            assertEq(vault.purchaseNonces(A), nonceBefore);
            assertEq(vault.spentInLast24Hours(A, asset), 0);
            assertEq(_available(A, asset), 100);
            assertEq(vault.pot(asset), 0);
            MockToken(asset).setFailure(false);
            vault.buyWithSig(A, ITEM, asset, 100, op, vm.getBlockTimestamp(), sig);
            assertEq(vault.purchaseNonces(A), nonceBefore + 1);
            assertEq(vault.spentInLast24Hours(A, asset), 100);
            assertEq(vault.pot(asset), 50);
        }
        _assertSolvent();
    }

    function test_oldOwnerPurchaseCannotReplayEvenAfterOwnershipReturns() public {
        _deposit(A, imd, 100);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory purchase = _sig(ALICE_KEY, _purchaseDigest(A, imd, 100, alice, deadline));
        bytes memory change = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, change);
        change = _sig(ALICE_KEY, _ownerDigest(A, alice, deadline));
        vm.prank(carol);
        vault.setOwner(A, alice, deadline, change);
        vm.expectRevert(NightshiftVault.InvalidSignature.selector);
        vault.buyWithSig(A, ITEM, imd, 100, alice, deadline, purchase);
        assertEq(_available(A, imd), 100);
        purchase = _sig(ALICE_KEY, _purchaseDigest(A, imd, 100, alice, deadline));
        vault.buyWithSig(A, ITEM, imd, 100, alice, deadline, purchase);
        _assertSolvent();
    }

    function test_newOwnerContractMustConsentAndReceivesLockedGameWinnings() public {
        TestWallet wallet = new TestWallet(carol);
        _deposit(A, imd, 100);
        _deposit(B, imd, 100);
        _lock("ownership during game", imd, 100);
        uint256 deadline = vm.getBlockTimestamp();
        bytes memory sig = _sig(CAROL_KEY, _ownerDigest(A, address(wallet), deadline));
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit NightshiftVault.OwnerSet(A, alice, address(wallet));
        vault.setOwner(A, address(wallet), deadline, sig);
        _settle("ownership during game", 0);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(alice);
        vault.withdraw(A, imd, 190);
        vm.prank(carol);
        wallet.execute(address(vault), abi.encodeCall(vault.withdraw, (A, imd, 190)));
        assertEq(_balance(address(wallet), imd), 190);
        _assertSolvent();
    }

    function test_defaultCapsAreSpecifiedAndSeparateByAccountAndAsset() public {
        assertEq(vault.DEFAULT_ETH_CAP(), 0.05 ether);
        assertEq(vault.DEFAULT_IMD_CAP(), 100 ether);
        assertEq(vault.DEFAULT_SHIFT_CAP(), 2_500_000 ether);
        _deposit(A, imd, 100 ether);
        vm.prank(op);
        vault.buy(A, ITEM, imd, 100 ether);
        assertEq(vault.spentInLast24Hours(A, imd), 100 ether);
        assertEq(vault.spentInLast24Hours(B, imd), 0);
        assertEq(vault.spentInLast24Hours(A, shift), 0);
        assertEq(vault.spentInLast24Hours(A, address(0)), 0);
        _deposit(A, shift, 2);
        vm.prank(op);
        vault.buy(A, ITEM, shift, 2);
        _assertSolvent();
    }

    function test_operatorRotationEnforcesActualAuthorityAtBoundary() public {
        _deposit(A, imd, 100);
        _deposit(B, imd, 100);
        uint256 start = vm.getBlockTimestamp();
        uint256 deadline = start + 3 days;
        bytes memory oldSig = _sig(OP_KEY, _purchaseDigest(A, imd, 2, op, deadline));
        vm.prank(vault.OWNER());
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, carol);
        vm.warp(start + 48 hours - 1);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(carol);
        vault.lockGame("early role", A, B, imd, 2, vm.getBlockTimestamp() + 1 hours);
        _lock("old role", imd, 2);
        _settle("old role", 2);
        vm.warp(start + 48 hours);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        _lock("retired role", imd, 2);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vault.buyWithSig(A, ITEM, imd, 2, op, deadline, oldSig);
        assertEq(vault.purchaseNonces(A), 0);
        vm.prank(carol);
        vault.lockGame("new role", A, B, imd, 2, vm.getBlockTimestamp() + 1 hours);
        _assertSolvent();
    }

    function test_legacyNoReturnTokenSupportsDepositSweepShopEscrowAndWithdrawal() public {
        EmptyReturnAsset implementation = new EmptyReturnAsset();
        for (uint256 i = 1; i < 3; ++i) {
            address asset = assets[i];
            vm.etch(asset, address(implementation).code);
            EmptyReturnAsset token = EmptyReturnAsset(asset);
            token.mint(address(this), 200);
            token.approve(address(vault), 200);
            vault.deposit(A, asset, 100);
            vault.deposit(B, asset, 100);
            token.mint(vault.depositAddress(A), 100);
            vault.sweep(A, asset);
            _lock(bytes32(i), asset, 100);
            _settle(bytes32(i), 0);
            vm.prank(alice);
            vault.buy(A, ITEM, asset, 100);
            vm.prank(alice);
            vault.withdraw(A, asset, 190);
            assertEq(token.balanceOf(alice), 190);
            assertEq(token.balanceOf(vault.FEE_SPLITTER()), 10);
            assertEq(token.balanceOf(asset == imd ? vault.IMD_BURN_EXECUTOR() : vault.DEAD()), 50);
        }
        _assertSolvent();
    }

    function test_burnRejectsIncorrectSettlementAndShortOutputTransferAtomically() public {
        _deposit(A, address(0), 5 ether);
        _direct(A, address(0), 2 ether);
        MockV4PoolManager manager = MockV4PoolManager(vault.POOL_MANAGER());
        manager.configure(100, false, false);
        MockToken(shift).mint(address(manager), 100);
        vm.mockCall(address(manager), abi.encodeCall(IV4PoolManager.settle, ()), abi.encode(uint256(1 ether - 1)));
        vm.expectRevert(NightshiftVault.InvalidSwap.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 100);
        vm.clearMockedCalls();
        MockToken(shift).setFee(true);
        vm.expectRevert(NightshiftVault.TransferAmountMismatch.selector);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 100);
        assertEq(vault.burnReserve(), 1 ether);
        assertEq(_balance(vault.DEAD(), shift), 0);
        assertEq(address(manager).balance, 0);
        assertEq(_balance(address(manager), shift), 100);
        assertEq(_available(A, address(0)), 5 ether);
        MockToken(shift).setFee(false);
        vm.prank(keeper);
        vault.burnReserve(1 ether, 100);
        _assertSolvent();
    }

    function test_counterfactualFundsSurvivePauseAndOwnershipChangeWithoutRedirection() public {
        for (uint256 i; i < 3; ++i) {
            address forwarder = vault.depositAddress(A);
            if (i == 0) {
                (bool ok,) = forwarder.call{value: 100}("");
                assertTrue(ok);
            } else {
                MockToken(assets[i]).mint(forwarder, 100);
            }
        }
        vm.prank(vault.OWNER());
        vault.setPaused(true);
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(NightshiftVault.IsPaused.selector);
            vault.sweep(A, assets[i]);
            assertEq(_balance(vault.depositAddress(A), assets[i]), 100);
        }
        uint256 deadline = vm.getBlockTimestamp();
        bytes memory signature = _sig(CAROL_KEY, _ownerDigest(A, carol, deadline));
        vm.prank(alice);
        vault.setOwner(A, carol, deadline, signature);
        vm.prank(vault.OWNER());
        vault.setPaused(false);
        for (uint256 i; i < 3; ++i) {
            vm.prank(bob);
            vault.sweep(A, assets[i]);
            uint256 beforeBalance = _balance(carol, assets[i]);
            vm.prank(carol);
            vault.withdraw(A, assets[i], 100);
            assertEq(_balance(carol, assets[i]), beforeBalance + 100);
            assertEq(_available(B, assets[i]), 0);
        }
        _assertSolvent();
    }

    function test_gameCanSettleAtLastGraceSecondButOnlyAvailableFundsWithdraw() public {
        for (uint256 i; i < 3; ++i) {
            _deposit(A, assets[i], 110);
            _deposit(B, assets[i], 100);
            _lock(bytes32(i + 1), assets[i], 100);
            vm.expectRevert(NightshiftVault.InsufficientBalance.selector);
            vm.prank(alice);
            vault.withdraw(A, assets[i], 11);
            vm.prank(alice);
            vault.withdraw(A, assets[i], 10);
        }
        vm.warp(vm.getBlockTimestamp() + 25 hours - 1);
        for (uint256 i; i < 3; ++i) {
            _settle(bytes32(i + 1), 0);
            assertEq(_available(A, assets[i]), 190);
            assertEq(_locked(A, assets[i]), 0);
        }
        _assertSolvent();
    }

    function test_keeperRotationChangesBurnPermissionAtExactBoundary() public {
        _direct(A, address(0), 4);
        MockV4PoolManager manager = MockV4PoolManager(vault.POOL_MANAGER());
        manager.configure(10, false, false);
        MockToken(shift).mint(address(manager), 20);
        uint256 start = vm.getBlockTimestamp();
        vm.prank(vault.OWNER());
        vault.scheduleRoleChange(NightshiftVault.Role.Keeper, carol);
        vm.warp(start + 48 hours - 1);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(carol);
        vault.burnReserve(1, 10);
        vm.prank(keeper);
        vault.burnReserve(1, 10);
        vm.warp(start + 48 hours);
        vm.expectRevert(NightshiftVault.Unauthorized.selector);
        vm.prank(keeper);
        vault.burnReserve(1, 10);
        vm.prank(carol);
        vault.burnReserve(1, 10);
        assertEq(vault.burnReserve(), 0);
        assertEq(vault.pot(address(0)), 2);
        assertEq(_balance(vault.DEAD(), shift), 20);
        _assertSolvent();
    }

    function test_custodyPurchaseAndPrizeEventsIdentifyCorrectAccountAssetAndAmount() public {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            if (asset != address(0)) {
                MockToken(asset).mint(address(this), 100);
                IERC20(asset).approve(address(vault), 100);
            }
            vm.expectEmit(true, true, true, true, address(vault));
            emit NightshiftVault.Deposited(A, asset, address(this), 100);
            if (asset == address(0)) vault.depositETH{value: 100}(A);
            else vault.deposit(A, asset, 100);
            vm.expectEmit(true, true, true, true, address(vault));
            emit NightshiftVault.Withdrawn(A, asset, alice, 20);
            vm.prank(alice);
            vault.withdraw(A, asset, 20);
            vm.expectEmit(true, true, true, true, address(vault));
            emit NightshiftVault.Purchased(A, ITEM, asset, 80);
            vm.prank(alice);
            vault.buy(A, ITEM, asset, 80);
            bytes32 root = _leaf(123, B, asset, 40);
            vm.expectEmit(true, true, false, true, address(vault));
            emit NightshiftVault.PrizesPosted(123, root, asset, 40, vm.getBlockTimestamp() + 30 days);
            vm.prank(op);
            vault.postPrizes(123, root, asset, 40);
            vm.expectEmit(true, true, true, true, address(vault));
            emit NightshiftVault.PrizeClaimed(123, B, asset, 40);
            vault.claimPrize(123, B, asset, 40, new bytes32[](0));
        }
        _assertSolvent();
    }

    function test_unfreezeReplacementRestartsFullDelayAndCapLoweringCancelsIncrease() public {
        uint256 start = vm.getBlockTimestamp();
        vm.startPrank(alice);
        vault.setFrozen(A, true);
        vault.setFrozen(A, false);
        vault.setCaps(A, imd, 200 ether, 40 ether);
        vm.warp(start + 23 hours);
        vault.setFrozen(A, false);
        vault.setCaps(A, imd, 50 ether, 10 ether);
        vm.stopPrank();
        vm.warp(start + 24 hours);
        assertTrue(vault.frozen(A));
        (uint256 daily, uint256 game) = vault.caps(A, imd);
        assertEq(daily, 50 ether);
        assertEq(game, 10 ether);
        vm.warp(start + 47 hours - 1);
        assertTrue(vault.frozen(A));
        vm.warp(start + 47 hours);
        assertFalse(vault.frozen(A));
        (daily, game) = vault.caps(A, imd);
        assertEq(daily, 50 ether);
        assertEq(game, 10 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedDepositWithdrawalRoundTripsCannotCreateValue(uint96 raw, uint8 assetIndex) public {
        uint256 amount = bound(raw, 1, 100 ether);
        address asset = assets[assetIndex % 3];
        if (asset == address(0)) vm.deal(alice, amount);
        else MockToken(asset).mint(alice, amount);
        uint256 initial = _balance(alice, asset);
        for (uint256 i; i < 6; ++i) {
            vm.startPrank(alice);
            if (asset == address(0)) {
                vault.depositETH{value: amount}(A);
            } else {
                IERC20(asset).approve(address(vault), amount);
                vault.deposit(A, asset, amount);
            }
            vault.withdraw(A, asset, amount);
            vm.stopPrank();
            assertEq(_balance(alice, asset), initial, "round-trip value changed");
            assertEq(_available(A, asset), 0);
        }
        _assertSolvent();
    }
}
