# NightshiftVault

An immutable Ethereum vault for NIGHTSHIFT account balances, operator-submitted games, purchases and leaderboard prizes. Player funds, prize funds and the ETH burn reserve are accounted for separately. Withdrawals always go to the account's current owner.

## Build and verify

The repository contains all Solidity dependencies as ordinary source files. Tests need no RPC, keys, environment values, filesystem permissions or FFI.

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer runs **200**, `via_ir = true`, and `bytecode_hash = "none"`. The fuzz seed is pinned to the assignment's `0xe236e55f669caf86dfbb177e0f87b21ebc014cb32978274dd7efd09a03a991d0`. Stateful invariant tests run 128 sequences of 64 operations. Dependency versions, sources and licenses are listed in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

## Deployment handoff

Deploy **only `src/NightshiftVault.sol:NightshiftVault`**, with **no constructor arguments** and **zero deployment ETH**, on **Ethereum mainnet, chain ID 1**. Its constructor needs no external contract calls or initialization. Ownership never depends on the factory, transaction sender or transaction origin.

`DepositForwarder` is created by the vault on demand using CREATE2. It is not a second application to deploy in the launch manifest. Contracts under `test/`, and the vendored Uniswap PoolManager, are test dependencies and must not be selected for deployment.

IdentityMD's deployment service supplies the factory transaction and confirmed vault address after acceptance. This deliverable does not broadcast transactions or supply a `launch.json`. Use the confirmed address as the EIP-712 verifying contract and as the address in both clients. Never precompute player addresses against an assumed vault address.

| Fixed setting | Value |
| --- | --- |
| Contract owner | `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5` |
| Initial operator, result signer and keeper | `0x3B5919586FC04F7e99b450a72bcB14Eeb6977497` |
| Native ETH asset identifier | `address(0)` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| SHIFT | `0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC` |
| Game fee splitter | `0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44` |
| IMD BurnExecutor | `0xe29386719C155B6847aD5a4E97C6674f10ffc750` |
| SHIFT burn destination | `0x000000000000000000000000000000000000dEaD` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| SHIFT pool hook | `0x42Ebcf86E3AB0445ba0362F911a7E8FAd6aCe0CC` |
| Pool key | currency0 ETH, currency1 SHIFT, fee `12500`, tick spacing `60`, hook above |

All amounts are integer base units. Both tokens have 18 decimals and no transfer fee, as specified in the assignment. ETH's zero-address identifier and SHIFT's dead-address recipient are explicit protocol values.

The PoolManager address comes from [Uniswap's Ethereum deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments). Its code and the code at the task's IMD, SHIFT, fee splitter, BurnExecutor, hook and reference GameEscrow addresses were observed on Ethereum during implementation. These observations are not embedded in constructors or required by offline tests.

The escrow lives inside this vault. It does not send stakes to the older [GameEscrow](https://eth.blockscout.com/address/0xf460fd9ad76f18414f54a2431870e8a116193489?tab=contract). It uses this assignment's result message, expiry rules, assets and balance credits.

## Accounts and signatures

`accountId` is a permanent, nonzero `bytes32`; the service should allocate an opaque identifier instead of publishing Telegram identifiers or other personal information. Several accounts may have the same wallet, but game participants must have distinct account IDs and distinct owners when locked.

Registration requires both owner and operator signatures. Anyone may relay registration. Only the current account owner can call `setOwner`; the proposed owner must also sign its acceptance. Ownership changes preserve balances, live games, spent-cap history and effective caps. They invalidate previous purchase authorizations and cancel pending cap increases and pending unfreezing.

EOA signatures and ERC-1271 contract wallets are supported. The EIP-712 domain is `NightshiftVault`, version `1`, with the current chain ID and vault address. Exact message schemas, nonces and integration steps are in [docs/INTEGRATION.md](docs/INTEGRATION.md).

## Deposits and withdrawals

`depositETH(accountId)` accepts ETH; `deposit(accountId, token, amount)` pulls approved IMD or SHIFT from the caller. Anyone can fund a registered account. Token receipts are measured and must match the requested amount.

`depositAddress(accountId)` predicts an ordinary CREATE2 forwarder, using `accountId` as its salt. Wallets and exchanges can transfer ETH or tokens there before it has code. Anyone can call `sweep(accountId, asset)` to deploy it if needed and credit its entire balance for that asset. Its immutable destination is this vault, and only this vault can invoke forwarding. There is no caller-selected forwarding recipient or account. Zero-balance sweeps are allowed.

Register an account before funding its forwarder. An unknown account cannot be credited or withdrawn. Unsupported tokens have no recovery route. Unlabelled ETH transfers directly to the vault revert; ERC-20 transfers directly to the vault are unallocated and cannot be rescued. Use the deposit functions or a personal forwarder.

`withdraw(accountId, asset, amount)` requires the current account owner and transfers only to that owner. It spends available funds, never locked stakes. It remains usable while paused or frozen. A failed transfer reverts the debit. A contract wallet must be able to receive ETH, or use an owner change to a consenting wallet that can.

## Games, caps and freezing

The operator submits `lockGame` when both players request a game through the NIGHTSHIFT service. The contract atomically locks both equal stakes, checks both balances and caps, and permanently consumes the nonzero game ID. No signature per game is required.

**Trust boundary:** the contract cannot observe a web or Telegram button press. Registration authorizes the operator to submit those requests within the on-chain limits. A compromised operator can misuse that bounded authority; caps and freezing limit exposure, not prove off-chain consent. The service must authenticate both requests and retain their audit records.

| Asset | Default rolling 24-hour cap | Default maximum stake per game |
| --- | ---: | ---: |
| ETH | 0.05 ETH | 0.01 ETH |
| IMD | 100 IMD | 20 IMD |
| SHIFT | 2,500,000 SHIFT | 500,000 SHIFT |

The per-game default is the named `DEFAULT_GAME_CAP_DIVISOR = 5` choice. Caps are independent for each account and asset. Every game stake and every operator-authorized balance purchase consumes the **same** rolling daily allowance. Settlement, draws, refunds, deposits and owner changes do not restore spent allowance. Owner-authorized purchases and externally funded purchases do not consume it.

The rolling interval is exactly `(now - 24 hours, now]`, rather than a calendar day or resetting window. Cumulative timestamp checkpoints and binary search make each query logarithmic in the number of historical spending timestamps. Same-timestamp spending is combined into one checkpoint; lifetime history remains in storage.

`setCaps` applies each decrease immediately and schedules each increase for 24 hours later. Mixed changes lower the restrictive component immediately. Every new call replaces the previous pending request. Zero caps disable operator spending for that asset. To cancel a pending increase, set the desired current or lower limits again. Lowering below already-spent amounts blocks new spending until enough history ages out.

`setFrozen(accountId, true)` immediately blocks new game locks and balance-funded purchases. `setFrozen(accountId, false)` schedules unfreezing after 24 hours. Re-freezing cancels that schedule. Deposits, withdrawals, existing game outcomes and prize claims still work; a third party can still purchase using its own money. The effective state changes automatically at the scheduled timestamp.

Game `expiresAt` must be in the future and no more than **24 hours** away (`MAX_GAME_DURATION`, an implementation choice preventing indefinite locks). Anyone can relay a signed result:

| Result | Balance outcome |
| --- | --- |
| `0` | A receives the pot minus its 5% fee |
| `1` | B receives the pot minus its 5% fee |
| `2` | Draw/void; each stake is returned, with no fee |

The fee is `floor(2 * stake / 20)` in raw units; the winner receives all rounding dust. It is transferred immediately to the fixed fee splitter. The signed deadline is inclusive. Settlement remains possible during the post-expiry grace period, but only **strictly before `expiresAt + 24 hours`**. At that exact timestamp, settlement closes and anyone can `refundGame`. No game can be settled or refunded twice.

## Shop and burning

`buy` spends a player's available balance when called by its owner or the operator. `buyWithSig` supports a relayer using an explicit, expiring EIP-712 owner/operator signature. An operator authorization is subject to the shared daily cap. `buyDirect` takes the caller's ETH or approved tokens and never debits player balances.

Purchases must have a **positive even number of raw units**, so no purchase rounds either half:

| Asset | Half of every purchase | Other half |
| --- | --- | --- |
| IMD | Transfer to the fixed IMD BurnExecutor | IMD prize pot |
| SHIFT | Transfer to the fixed dead address | SHIFT prize pot |
| ETH | ETH burn reserve | ETH prize pot |

`Purchased` is the purchase receipt. The game service defines and validates the catalog, asset-specific prices, item IDs and entitlements; the contract does not invent a catalog or price feed. A receipt for an arbitrary amount must not grant an item unless it satisfies the service's catalog.

The keeper calls `burnReserve(amountIn, minShiftOut)` with a positive minimum. The vault directly uses the fixed Uniswap v4 PoolManager and pool key, performs an exact-input ETH-to-SHIFT swap, settles the ETH debt, and takes all purchased SHIFT directly to the dead address in the same transaction. It checks the received amount there. Insufficient reserve, bad callback, partial input consumption, insufficient output or failed settlement reverts the entire burn. No ERC-20 approval or external router is involved.

`burnReserve()` without arguments returns the reserved ETH amount. Player ETH and prize ETH cannot be used for burning. The keeper must quote current liquidity and choose a meaningful minimum; a positive minimum alone does not guarantee a fair market price. The pool must be initialized, have usable liquidity and permit trading.

## Weekly prizes

The operator assigns epoch numbers (recommended convention: `floor(weekStartUnix / 604800)`) and publishes a StandardMerkleTree root for each asset. Calendar cadence is enforced by operations; the contract enforces uniqueness of each `(epoch, asset)` forever.

`postPrizes` moves `total` out of the asset's unreserved pot into that epoch's reservation. It cannot reserve player money, ETH burn reserve, another asset's pot or funds already promised by another epoch.

The leaf is exactly:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(epoch, accountId, asset, amount))))
```

Anyone may relay `claimPrize`; credit always goes to the leaf's account. Proof pairs are sorted, matching OpenZeppelin StandardMerkleTree. A leaf is claimable once across the vault, and the epoch's remaining allocation bounds every credit. The service must check the sum of its leaf amounts before posting: an oversubscribed root does not create funds and would leave some valid leaves unpayable.

Claims are valid strictly before 30 days after posting. At that boundary, anyone can call `expirePrizes` to return only the unclaimed remainder to the same asset's pot. Roots cannot be replaced, extended, reposted or redirected. Claims track account IDs, so a consented owner change changes who can subsequently withdraw a prize.

## Roles, pause and operating responsibilities

`scheduleRoleChange(role, newAddress)` is restricted to the fixed contract owner. Roles are `0 = Operator`, `1 = ResultSigner`, `2 = Keeper`. Every change takes a full **48 hours**, including replacements of pending changes. An unmatured change can be cancelled. The effective role getter switches automatically at the deadline; `applyRoleChange` is an optional, permissionless materialization for indexers. Cancelling a change after it has become effective is not allowed.

The contract owner can pause only **new deposits (including sweeps), game locks and purchases**. Registration, owner changes, limits, freezing, withdrawals, game settlement/refunds, burns, prize posting/claims/expiry and delayed-role administration remain available. A forwarder can still receive transfers while paused, but their credit waits for deposits to reopen.

| Responsible party | Operational work |
| --- | --- |
| Account owner | Check registration details; review caps; freeze or lower exposure when needed; protect ownership and purchase signatures; withdraw to its own wallet |
| Operator | Authenticate game requests; co-sign registrations; submit locks; enforce the shop catalog; publish correct weekly roots and accessible proofs |
| Result signer | Verify outcomes independently of request submission; sign correct, short-lived results; stop issuing old-role signatures before rotations become effective |
| Keeper | Quote the fixed pool; choose slippage limits; submit reserve burns; account for MEV and pool/hook availability |
| Contract owner | Monitor the system; pause new intake if needed; schedule and monitor role changes; cannot recover, transfer or redirect user funds |
| Anyone / service automation | Sweep personal deposits, relay valid results/claims, refund timed-out games, expire old prize allocations |

All three operational roles start at the address requested by the brief. Separate operational wallets can be assigned with the 48-hour delay. The fixed administrative owner has no ownership-transfer function.

## After launch

There are **no missing deployment parameters, placeholders or required initialization setters**. The owner only changes roles or pause state through the functions above when operations require it.

Before enabling deposits, the deployment service should verify source and deployed runtime, the mainnet chain ID, constants and role getters. The clients should register users and show each registered account's confirmed deposit address. Operations should verify the fixed pool key, hook trading state, liquidity and each fixed recipient's expected behavior before enabling the corresponding feature.

Monitor scheduled roles and caps using their timestamps and current view getters, rather than expecting a transaction at the instant a delay expires. Monitor locked games for refund eligibility and prize epochs for expiration. Publish the complete Merkle data and proofs alongside each weekly root.

The code review notes and validation scope are in [docs/SECURITY.md](docs/SECURITY.md), with local results in [docs/VALIDATION.md](docs/VALIDATION.md). An independent adversarial review remains a release responsibility; local tests do not replace it.
