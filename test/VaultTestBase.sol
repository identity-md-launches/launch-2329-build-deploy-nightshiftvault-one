// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NightshiftVault} from "../src/NightshiftVault.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockToken, TestWallet, RejectETH} from "./mocks/MockAssets.sol";
import {MockV4PoolManager} from "./mocks/MockV4PoolManager.sol";

abstract contract VaultTestBase is Test {
    NightshiftVault internal vault;
    uint256 internal constant ALICE_KEY = 0xa11ce;
    uint256 internal constant BOB_KEY = 0xb0b;
    uint256 internal constant CAROL_KEY = 0xca401;
    uint256 internal constant OP_KEY = 0x0a011;
    uint256 internal constant RESULT_KEY = 0x123456;
    uint256 internal constant KEEPER_KEY = 0x9999;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal op;
    address internal resultSigner;
    address internal keeper;
    address internal imd;
    address internal shift;
    bytes32 internal constant A = keccak256("alice");
    bytes32 internal constant B = keccak256("bob");
    bytes32 internal constant C = keccak256("carol");
    bytes32 internal constant ITEM = keccak256("item");
    address[3] internal assets;

    function setUp() public virtual {
        vm.warp(10 days);
        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);
        carol = vm.addr(CAROL_KEY);
        op = vm.addr(OP_KEY);
        resultSigner = vm.addr(RESULT_KEY);
        keeper = vm.addr(KEEPER_KEY);
        vault = new NightshiftVault();
        imd = vault.IMD();
        shift = vault.SHIFT();
        assets = [address(0), imd, shift];
        MockToken implementation = new MockToken();
        vm.etch(imd, address(implementation).code);
        vm.etch(shift, address(implementation).code);
        MockV4PoolManager manager = new MockV4PoolManager();
        vm.etch(vault.POOL_MANAGER(), address(manager).code);
        vm.startPrank(vault.OWNER());
        vault.scheduleRoleChange(NightshiftVault.Role.Operator, op);
        vault.scheduleRoleChange(NightshiftVault.Role.ResultSigner, resultSigner);
        vault.scheduleRoleChange(NightshiftVault.Role.Keeper, keeper);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _register(A, alice, ALICE_KEY);
        _register(B, bob, BOB_KEY);
        _register(C, carol, CAROL_KEY);
        vm.deal(address(this), 1_000_000 ether);
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _typed(bytes32 hash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), hash));
    }

    function _registrationDigest(bytes32 id, address owner, uint256 deadline) internal view returns (bytes32) {
        return _typed(keccak256(abi.encode(vault.REGISTER_TYPEHASH(), id, owner, deadline)));
    }

    function _register(bytes32 id, address owner, uint256 key) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = _registrationDigest(id, owner, deadline);
        vault.register(id, owner, deadline, _sig(key, digest), _sig(OP_KEY, digest));
    }

    function _deposit(bytes32 id, address asset, uint256 amount) internal {
        if (asset == address(0)) {
            vault.depositETH{value: amount}(id);
        } else {
            MockToken(asset).mint(address(this), amount);
            IERC20(asset).approve(address(vault), amount);
            vault.deposit(id, asset, amount);
        }
    }

    function _direct(bytes32 id, address asset, uint256 amount) internal {
        if (asset == address(0)) {
            vault.buyDirect{value: amount}(id, ITEM, asset, amount);
        } else {
            MockToken(asset).mint(address(this), amount);
            IERC20(asset).approve(address(vault), amount);
            vault.buyDirect(id, ITEM, asset, amount);
        }
    }

    function _lock(bytes32 gameId, address asset, uint256 stake) internal {
        vm.prank(op);
        vault.lockGame(gameId, A, B, asset, stake, vm.getBlockTimestamp() + 1 hours);
    }

    function _resultSig(bytes32 gameId, uint8 result, uint256 deadline, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        return _sig(key, _typed(keccak256(abi.encode(vault.RESULT_TYPEHASH(), gameId, result, deadline))));
    }

    function _settle(bytes32 gameId, uint8 result) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vault.settle(gameId, result, deadline, _resultSig(gameId, result, deadline, RESULT_KEY));
    }

    function _available(bytes32 id, address asset) internal view returns (uint256 amount) {
        (amount,) = vault.balanceOf(id, asset);
    }

    function _locked(bytes32 id, address asset) internal view returns (uint256 amount) {
        (, amount) = vault.balanceOf(id, asset);
    }

    function _balance(address account, address asset) internal view returns (uint256) {
        return asset == address(0) ? account.balance : IERC20(asset).balanceOf(account);
    }

    function _assertSolvent() internal view {
        for (uint256 i; i < 3; ++i) {
            address asset = assets[i];
            uint256 sum = _available(A, asset) + _available(B, asset) + _available(C, asset) + _locked(A, asset)
                + _locked(B, asset) + _locked(C, asset);
            assertEq(sum, vault.totalPlayerFunds(asset), "player ledger");
            assertLe(vault.accountedHoldings(asset), _balance(address(vault), asset), "insolvent");
        }
    }

    function _leaf(uint256 epoch, bytes32 id, address asset, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, id, asset, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _ownerDigest(bytes32 id, address next, uint256 deadline) internal view returns (bytes32) {
        return _typed(
            keccak256(
                abi.encode(vault.OWNER_TYPEHASH(), id, vault.accountOf(id), next, vault.ownerNonces(id), deadline)
            )
        );
    }

    function _purchaseDigest(bytes32 id, address asset, uint256 amount, address signer, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return _typed(
            keccak256(
                abi.encode(
                    vault.PURCHASE_TYPEHASH(),
                    id,
                    ITEM,
                    asset,
                    amount,
                    signer,
                    vault.purchaseNonces(id),
                    vault.ownerNonces(id),
                    deadline
                )
            )
        );
    }
}
