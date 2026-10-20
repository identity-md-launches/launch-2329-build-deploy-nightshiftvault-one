# Client and service integration

Use the deployed vault ABI from `out/NightshiftVault.sol/NightshiftVault.json`. Both the web client and Telegram Mini App use the same account, balance and signature model. No client needs a private backend key.

## Typed data

Domain fields:

```text
name: NightshiftVault
version: 1
chainId: 1                    (Ethereum deployment)
verifyingContract: confirmed deployed NightshiftVault address
```

The on-chain `DOMAIN_SEPARATOR()` binds the actual chain ID and deployment address. A signature from another deployment or chain is invalid. EOAs use normal EIP-712 signatures; ERC-1271 wallets are queried by `isValidSignature`.

### Register

```text
Register(bytes32 accountId,address owner,uint256 deadline)
```

The owner and current operator sign the same message. Submit:

```text
register(accountId, owner, deadline, ownerSig, operatorSig)
```

The permanent account ID is its replay nonce: registration never becomes reusable, including after an owner change. The operator should not co-sign a second identity assignment for a previously allocated ID.

### SetOwner

```text
SetOwner(bytes32 accountId,address owner,address newOwner,uint256 nonce,uint256 deadline)
```

Read `accountOf(accountId)` for `owner` and `ownerNonces(accountId)` for `nonce`. The proposed new owner signs the message. The current owner submits `setOwner(accountId, newOwner, deadline, newOwnerSig)`. `ownerNonces` increments only after a successful change, so an old acceptance cannot be reused if ownership later cycles back.

### Result

```text
Result(bytes32 gameId,uint8 result,uint256 deadline)
```

Only the current effective result signer's signature is accepted. Result values are `0 = A won`, `1 = B won`, `2 = draw/void`. Anyone can submit `settle(gameId, result, deadline, sig)`. The permanently unique game ID and terminal game state prevent replay.

The service must choose a deadline that allows relay before the game's refund boundary. A role rotation immediately invalidates the previous signer's messages when the 48-hour delay expires, even for previously locked games.

### Purchase

```text
Purchase(bytes32 accountId,bytes32 itemId,address asset,uint256 amount,address signer,uint256 nonce,uint256 ownerNonce,uint256 deadline)
```

Read `purchaseNonces(accountId)` for `nonce`, and `ownerNonces(accountId)` for `ownerNonce`. `signer` must be the current account owner or effective operator. Relay through:

```text
buyWithSig(accountId, itemId, asset, amount, signer, deadline, sig)
```

The shared account purchase nonce increments on a successful relayed purchase. A reverted purchase consumes nothing. The owner may invalidate outstanding signatures with `invalidatePurchaseNonce(accountId, newNonce)`, where `newNonce` must exceed the current value.

Direct `buy` uses the caller's transaction authorization and does not consume this relay nonce. Direct purchases also do not invalidate outstanding signed purchases; use the nonce invalidation function to cancel them. An owner change invalidates prior signatures through `ownerNonce`, including prior operator signatures. Re-check nonces when parallel clients are active.

All signed deadlines are inclusive: a signature is valid at `block.timestamp == deadline`. A purchase remains subject to pause/freeze, balance and (for operator authorizations) rolling-cap checks when executed.

## Deposit and withdrawal flow

1. Register the account with both signatures and wait for confirmation.
2. Read `accountOf(accountId)` and `depositAddress(accountId)`.
3. Display that address for exchange transfers of only ETH, IMD or SHIFT on Ethereum.
4. Call or relay `sweep(accountId, asset)` after funding. Each asset is swept separately.
5. Read `balanceOf(accountId, asset)` to display available and locked balances.
6. The account owner calls `withdraw`; there is no recipient input.

An ERC-20 `deposit` or token `buyDirect` requires the payer to approve the vault. Approve the intended amount. ETH functions use `msg.value`. For ETH `buyDirect`, the supplied value must exactly equal `amount`; token purchases must send zero ETH.

For balance purchases, display the authorized amount and item. The app must not treat an arbitrary `Purchased` event as entitlement without validating the current catalog. Both account owner and payer can differ in `buyDirect`.

## Reading delayed settings

`caps(accountId, asset)` and `frozen(accountId)` return the effective state. `capConfiguration` and `freezeState` return stored schedules as well. An increased cap or unfreeze takes effect at its `readyAt`/`unfreezeAt`, without an activation transaction.

`operator()`, `resultSigner()` and `keeper()` likewise return effective roles, even if `roleChanges` still contains their already-matured schedules. A `RoleScheduled` event records when the change becomes effective. `RoleSet` is emitted when a schedule is optionally materialized with `applyRoleChange`.

`CapsSet` describes immediate limits; `CapsScheduled` describes future limits and their timestamp. `CapsCancelled` and `OwnerSet` invalidate outstanding schedules. `Frozen(accountId, false, futureTimestamp)` announces an unfreeze request; it does not mean the account is already unfrozen.

## Merkle format

Build an OpenZeppelin StandardMerkleTree using these exact ABI types, in order:

```text
["uint256", "bytes32", "address", "uint256"]
```

Rows are `[epoch, accountId, asset, amount]`. Use decimal strings or exact integers for amounts, never floating-point token amounts. StandardMerkleTree double-hashes ABI-encoded rows and sorts sibling pairs. A single-leaf tree's root is the leaf and its proof is empty.

Publish the tree data, root, asset, epoch and sum of leaves. De-duplicate identical leaves and check the sum equals the proposed reservation before calling `postPrizes`. Nonzero amounts and registered accounts are required for claims. The contract permits multiple distinct leaves for one account in an epoch, but rejects the same leaf twice.

`epochs(epoch, asset)` returns `(root, total, remaining, expiresAt, expired)`. `claimed(leaf)` reports the consumed leaf. A root can never be replaced, including after all its funds are claimed or expired.

## Monitoring accounting

For each supported asset:

```text
totalPlayerFunds
  = sum(available + locked) over registered accounts

accountedHoldings
  = totalPlayerFunds + pot + reservedPrizes
    + burnReserve (only for ETH)
```

The latter must not exceed the vault's actual ETH/token holdings. `reservedPrizes` includes posted-but-unclaimed prizes even after their claim deadline, until `expirePrizes` moves them back to `pot`. Forwarder balances are outside vault holdings until swept.

Donations directly to the vault are not a pot funding method. They do not grant withdrawal rights or increase any ledger.
