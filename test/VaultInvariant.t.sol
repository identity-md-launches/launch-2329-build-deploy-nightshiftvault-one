// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken} from "./mocks/MockAssets.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";

/// @dev Exercises only valid actions, so fail_on_revert detects unexpected implementation failures.
contract VaultHandler is Test {
    NightshiftVault public immutable vault;
    address[3] private _assets;
    bytes32[3] private _accounts;
    address[3] private _owners;
    address private _operator;
    address private _keeper;
    bytes32[] private _gameIds;
    uint256 private constant RESULT_KEY = 0x123456;
    uint256 private _epochCounter;

    struct Prize {
        uint256 epoch;
        bytes32 accountId;
        address asset;
        uint256 amount;
    }
    Prize[] private _prizes;
    mapping(address => uint256) public inflows;
    mapping(address => uint256) public outflows;
    mapping(bytes4 => uint256) public calls;

    constructor(NightshiftVault vault_, address[3] memory owners_) {
        vault = vault_;
        _assets = [address(0), vault_.IMD(), vault_.SHIFT()];
        _accounts = [keccak256("alice"), keccak256("bob"), keccak256("carol")];
        _owners = owners_;
        _operator = vault_.operator();
        _keeper = vault_.keeper();
    }

    function deposit(uint8 accountIndex, uint8 assetIndex, uint96 raw) external {
        if (vault.paused()) return;
        address asset = _assets[assetIndex % 3];
        bytes32 id = _accounts[accountIndex % 3];
        uint256 amount = bound(raw, 1, 10 ether);
        if (asset == address(0)) {
            vault.depositETH{value: amount}(id);
        } else {
            _fund(asset, amount);
            vault.deposit(id, asset, amount);
        }
        inflows[asset] += amount;
        ++calls[this.deposit.selector];
    }

    function sweep(uint8 accountIndex, uint8 assetIndex, uint96 raw) external {
        if (vault.paused()) return;
        address asset = _assets[assetIndex % 3];
        bytes32 id = _accounts[accountIndex % 3];
        uint256 amount = bound(raw, 1, 1 ether);
        address forwarder = vault.depositAddress(id);
        if (asset == address(0)) {
            (bool ok,) = forwarder.call{value: amount}("");
            require(ok);
        } else {
            MockToken(asset).mint(forwarder, amount);
        }
        vault.sweep(id, asset);
        inflows[asset] += amount;
        ++calls[this.sweep.selector];
    }

    function withdraw(uint8 accountIndex, uint8 assetIndex, uint96 raw) external {
        uint256 account = accountIndex % 3;
        address asset = _assets[assetIndex % 3];
        (uint256 available,) = vault.balanceOf(_accounts[account], asset);
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        vm.prank(_owners[account]);
        vault.withdraw(_accounts[account], asset, amount);
        outflows[asset] += amount;
        ++calls[this.withdraw.selector];
    }

    function lock(uint8 accountIndex, uint8 assetIndex, uint96 raw) external {
        if (vault.paused()) return;
        bytes32 a = _accounts[accountIndex % 3];
        bytes32 b = _accounts[(uint256(accountIndex) + 1) % 3];
        address asset = _assets[assetIndex % 3];
        if (vault.frozen(a) || vault.frozen(b)) return;
        uint256 allowed = _min(_allowance(a, asset, true), _allowance(b, asset, true));
        if (allowed == 0) return;
        uint256 stake = bound(raw, 1, allowed);
        bytes32 id = keccak256(abi.encode("invariant game", _gameIds.length));
        _gameIds.push(id);
        vm.prank(_operator);
        vault.lockGame(id, a, b, asset, stake, vm.getBlockTimestamp() + 1 hours);
        ++calls[this.lock.selector];
    }

    function settleOrRefund(uint256 index, uint8 result) external {
        if (_gameIds.length == 0) return;
        bytes32 id = _gameIds[index % _gameIds.length];
        (,, address asset, uint256 stake, uint256 expiresAt, NightshiftVault.GameStatus status,) = vault.games(id);
        if (status != NightshiftVault.GameStatus.Locked) return;
        if (vm.getBlockTimestamp() >= expiresAt + 24 hours) {
            vault.refundGame(id);
        } else {
            result %= 3;
            uint256 deadline = vm.getBlockTimestamp();
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    vault.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(vault.RESULT_TYPEHASH(), id, result, deadline))
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(RESULT_KEY, digest);
            vault.settle(id, result, deadline, abi.encodePacked(r, s, v));
            if (result != 2) outflows[asset] += 2 * stake / 20;
        }
        ++calls[this.settleOrRefund.selector];
    }

    function buy(uint8 accountIndex, uint8 assetIndex, uint96 raw, bool operatorPurchase) external {
        if (vault.paused()) return;
        uint256 account = accountIndex % 3;
        bytes32 id = _accounts[account];
        address asset = _assets[assetIndex % 3];
        if (vault.frozen(id)) return;
        (uint256 available,) = vault.balanceOf(id, asset);
        if (operatorPurchase) available = _allowance(id, asset, false);
        if (available < 2) return;
        uint256 amount = bound(raw, 1, available / 2) * 2;
        vm.prank(operatorPurchase ? _operator : _owners[account]);
        vault.buy(id, keccak256("item"), asset, amount);
        if (asset != address(0)) outflows[asset] += amount / 2;
        ++calls[this.buy.selector];
    }

    function buyDirect(uint8 accountIndex, uint8 assetIndex, uint96 raw) external {
        if (vault.paused()) return;
        bytes32 id = _accounts[accountIndex % 3];
        address asset = _assets[assetIndex % 3];
        uint256 amount = bound(raw, 1, 10 ether) * 2;
        if (asset == address(0)) {
            vault.buyDirect{value: amount}(id, keccak256("item"), asset, amount);
        } else {
            _fund(asset, amount);
            vault.buyDirect(id, keccak256("item"), asset, amount);
            outflows[asset] += amount / 2;
        }
        inflows[asset] += amount;
        ++calls[this.buyDirect.selector];
    }

    function post(uint8 accountIndex, uint8 assetIndex, uint96 raw) external {
        address asset = _assets[assetIndex % 3];
        bytes32 id = _accounts[accountIndex % 3];
        uint256 availablePot = vault.pot(asset);
        if (availablePot == 0) return;
        uint256 amount = bound(raw, 1, availablePot);
        uint256 epoch = ++_epochCounter;
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(epoch, id, asset, amount))));
        vm.prank(_operator);
        vault.postPrizes(epoch, root, asset, amount);
        _prizes.push(Prize(epoch, id, asset, amount));
        ++calls[this.post.selector];
    }

    function claimOrExpire(uint256 index) external {
        if (_prizes.length == 0) return;
        Prize memory prize = _prizes[index % _prizes.length];
        (,, uint256 remaining, uint256 expiresAt, bool expired) = vault.epochs(prize.epoch, prize.asset);
        if (expired) return;
        if (vm.getBlockTimestamp() >= expiresAt) {
            vault.expirePrizes(prize.epoch, prize.asset);
        } else if (remaining != 0) {
            vault.claimPrize(prize.epoch, prize.accountId, prize.asset, prize.amount, new bytes32[](0));
        }
        ++calls[this.claimOrExpire.selector];
    }

    function burn(uint96 raw) external {
        uint256 reserve = vault.burnReserve();
        if (reserve == 0) return;
        uint256 amount = bound(raw, 1, reserve);
        address manager = vault.POOL_MANAGER();
        MockV4PoolManager(manager).configure(amount * 2, false, false);
        MockToken(_assets[2]).mint(manager, amount * 2);
        vm.prank(_keeper);
        vault.burnReserve(amount, amount * 2);
        outflows[address(0)] += amount;
        ++calls[this.burn.selector];
    }

    function advanceTime(uint32 secondsForward) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsForward, 0, 31 days));
        ++calls[this.advanceTime.selector];
    }

    function freeze(uint8 accountIndex, bool value) external {
        uint256 account = accountIndex % 3;
        if (!value && !vault.frozen(_accounts[account])) return;
        vm.prank(_owners[account]);
        vault.setFrozen(_accounts[account], value);
        ++calls[this.freeze.selector];
    }

    function setCaps(uint8 accountIndex, uint8 assetIndex, uint96 rawDaily, uint96 rawGame) external {
        uint256 account = accountIndex % 3;
        vm.prank(_owners[account]);
        vault.setCaps(_accounts[account], _assets[assetIndex % 3], rawDaily % 100 ether, rawGame % 20 ether);
        ++calls[this.setCaps.selector];
    }

    function pause(bool value) external {
        vm.prank(vault.OWNER());
        vault.setPaused(value);
        ++calls[this.pause.selector];
    }

    function gameCount() external view returns (uint256) {
        return _gameIds.length;
    }

    function gameId(uint256 index) external view returns (bytes32) {
        return _gameIds[index];
    }

    function prizeCount() external view returns (uint256) {
        return _prizes.length;
    }

    function prizeAt(uint256 index) external view returns (Prize memory) {
        return _prizes[index];
    }

    function _fund(address asset, uint256 amount) private {
        MockToken(asset).mint(address(this), amount);
        IERC20(asset).approve(address(vault), amount);
    }

    function _allowance(bytes32 id, address asset, bool game) private view returns (uint256) {
        (uint256 daily, uint256 perGame) = vault.caps(id, asset);
        uint256 spent = vault.spentInLast24Hours(id, asset);
        if (spent >= daily) return 0;
        (uint256 available,) = vault.balanceOf(id, asset);
        available = _min(available, daily - spent);
        return game ? _min(available, perGame) : available;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract VaultInvariantTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, [alice, bob, carol]);
        vm.deal(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.sweep.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.lock.selector;
        selectors[4] = handler.settleOrRefund.selector;
        selectors[5] = handler.buy.selector;
        selectors[6] = handler.buyDirect.selector;
        selectors[7] = handler.post.selector;
        selectors[8] = handler.claimOrExpire.selector;
        selectors[9] = handler.burn.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.freeze.selector;
        selectors[12] = handler.setCaps.selector;
        selectors[13] = handler.pause.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allLiabilitiesBackedAndExternalFlowsConserved() public view {
        _assertSolvent();
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            uint256 holdings = _balance(address(vault), asset);
            assertEq(vault.accountedHoldings(asset), holdings, "unaccounted funds");
            assertEq(holdings + handler.outflows(asset), handler.inflows(asset), "external conservation");
        }
    }

    function invariant_lockedBalancesEqualAllLiveGameStakes() public view {
        bytes32[3] memory accounts = [A, B, C];
        for (uint256 a; a < 3; ++a) {
            for (uint256 t; t < 3; ++t) {
                uint256 expected;
                for (uint256 i; i < handler.gameCount(); ++i) {
                    (
                        bytes32 accountA,
                        bytes32 accountB,
                        address asset,
                        uint256 stake,,
                        NightshiftVault.GameStatus status,
                    ) = vault.games(handler.gameId(i));
                    if (
                        status == NightshiftVault.GameStatus.Locked && asset == assets[t]
                            && (accounts[a] == accountA || accounts[a] == accountB)
                    ) expected += stake;
                }
                assertEq(_locked(accounts[a], assets[t]), expected, "game ledger");
            }
        }
    }

    function invariant_epochReservationsEqualUnclaimedPrizes() public view {
        for (uint256 a; a < 3; ++a) {
            uint256 expected;
            for (uint256 i; i < handler.prizeCount(); ++i) {
                VaultHandler.Prize memory prize = handler.prizeAt(i);
                if (prize.asset != assets[a]) continue;
                (,, uint256 remaining,,) = vault.epochs(prize.epoch, prize.asset);
                expected += remaining;
            }
            assertEq(vault.reservedPrizes(assets[a]), expected, "epoch ledger");
        }
    }

    /// @dev Deterministic traversal ensures every economic transition is exercised even before fuzzing.
    function test_handlerTraversesAllEconomicTransitions() public {
        handler.deposit(0, 0, 1 ether);
        handler.deposit(1, 0, 1 ether);
        handler.lock(0, 0, 0.01 ether);
        handler.settleOrRefund(0, 0);
        handler.sweep(2, 1, 1 ether);
        handler.buy(2, 1, 0.1 ether, true);
        handler.buy(2, 1, 0.1 ether, false);
        handler.buyDirect(0, 2, 10 ether);
        handler.post(1, 2, 1 ether);
        handler.claimOrExpire(0);
        handler.withdraw(1, 2, 0.5 ether);
        handler.post(2, 2, 1 ether);
        handler.advanceTime(31 days);
        handler.claimOrExpire(1);
        handler.buyDirect(0, 0, 1 ether);
        handler.burn(1 ether);
        invariant_allLiabilitiesBackedAndExternalFlowsConserved();
        invariant_lockedBalancesEqualAllLiveGameStakes();
        invariant_epochReservationsEqualUnclaimedPrizes();
        assertGt(handler.calls(handler.lock.selector), 0);
        assertGt(handler.calls(handler.claimOrExpire.selector), 0);
        assertGt(handler.calls(handler.burn.selector), 0);
    }
}
