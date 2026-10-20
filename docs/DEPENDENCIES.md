# Vendored dependencies

All required dependency source files and licenses are delivered under `lib/`. There are no Git submodules, external library links, package-manager downloads at build time or dependencies under `node_modules`.

| Package | Exact source | Use | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | SafeERC20, EIP-712, signature checks, MerkleProof, ReentrancyGuard; ERC20 test mock | `lib/openzeppelin-contracts/LICENSE` (MIT) |
| Forge Standard Library | [v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | Tests only | `lib/forge-std/LICENSE-MIT`, `LICENSE-APACHE` |
| Uniswap v4 core | [v4.0.0](https://github.com/Uniswap/v4-core/tree/v4.0.0) | Local protocol integration tests only | `lib/v4-core/licenses/BUSL_LICENSE`, `MIT_LICENSE`; each source states its license |
| Solmate | [4b47a19038b798b4a33d9749d25e570443520647](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `Owned.sol`, used by the test PoolManager; this is v4.0.0's pinned dependency | `lib/solmate/LICENSE` (AGPL-3.0; `Owned.sol` has its own AGPL-3.0-only SPDX header) |

The dependency trees are trimmed to the transitive Solidity imports used by this project; retained source files are unmodified upstream files. `lib/SHA256SUMS` records their contents and license files:

```sh
sha256sum -c lib/SHA256SUMS
```

Production code uses a small independent ABI interface for the canonical external PoolManager, at `src/interfaces/IV4PoolManager.sol`. No Uniswap or Solmate implementation is deployed with NightshiftVault. All production library functions are internal and inlined.

The official PoolManager interface and implementation at the pinned tag define the unlock callback, `swap`, packed signed balance deltas, `sync`, `settle` and `take`. The offline integration test executes the unmodified core against a local pool and a controlled hook with the requested address permission bits. This checks ABI compatibility and flash-accounting settlement without depending on mainnet state.
