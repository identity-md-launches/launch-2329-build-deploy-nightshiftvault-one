# Local validation

Validated with Forge **1.8.3** and the pinned Solidity **0.8.26** configuration.

| Check | Result |
| --- | --- |
| `forge build` | Pass, including a clean rebuild |
| `forge test` | 56 reported tests passed; zero failures or skips |
| `forge fmt --check` | Pass |
| Vendored dependency checksums | All match `lib/SHA256SUMS` |
| NightshiftVault runtime | 19,671 bytes, below the 24,576-byte limit |
| NightshiftVault initcode | 20,881 bytes, below the 49,152-byte limit |
| DepositForwarder runtime / initcode | 882 / 1,078 bytes |
| Production external library links | None |
| Deployment runtime opcode checks | Pass for vault and forwarder |

The test suite includes four parameterized fuzz tests with 256 cases each and the assignment's pinned seed:

```text
0xe236e55f669caf86dfbb177e0f87b21ebc014cb32978274dd7efd09a03a991d0
```

Three stateful invariants passed together over 128 sequences of depth 64: 8,192 handler calls with zero unexpected reverts. Forge reports these as one invariant group. A deterministic handler traversal also covers the major economic transitions.

The two local Uniswap integration tests execute unmodified v4.0.0 core with controlled tokens and a hook. They verify actual flash-accounting settlement, output delivery to the burn destination, slippage rollback and blocked hook reentry. They require no network fork.

Forge's heuristic lints still flag intentional timestamp comparisons, guarded external interactions, fixed-length CREATE2 bytecode concatenation and packed signed-delta conversions. The guard, callback restrictions, cast bounds and transfer destinations were reviewed and exercised by the tests; these diagnostics were not globally suppressed.

These are local checks, not independent acceptance or an audit. No live deployment, broadcast, explorer verification, Slither or Mythril run is claimed.
