# Security review and validation scope

This is the implementation's review record, not an independent security audit. A separate adversarial review is required before release.

## Custody and authority

The contract owner has only pause and delayed operational-role administration. There is no administrative withdrawal, approval, arbitrary call, asset addition, recipient setter, fee setter, ownership recovery, proxy, delegatecall or selfdestruct path. `sweep` is limited to a vault-derived personal forwarder and credits only its immutable account.

Account owners can withdraw only available funds and only to themselves. They can transfer account ownership only with the successor's signature. Ownership changes preserve live escrow obligations and spending history and cancel pending relaxations. Two independently registered accounts owned by one wallet cannot be paired in a new game.

The operator is trusted to authenticate off-chain game and shop requests and publish correct leaderboard results. On-chain limits bound operator game/shop spending per account and asset. The result signer determines the winner of already locked stakes. The keeper controls timing and minimum output for reserve burns. Administrative role rotation can eventually change these trusted parties, with a 48-hour notice period.

The initial three roles share the brief's single address. Compromise of that address compromises all three roles; the implementation does not imply independent keys at launch. The cap is a per-account spending limit, not a per-wallet/global loss bound. A game refund does not reset it, but each elapsed rolling day restores allowance.

## Accounting

Player available and locked amounts sum to `totalPlayerFunds`. Posting prizes moves funds from `pot` to `reservedPrizes`; claiming moves them into player funds; expiry moves only the remainder back to the pot. ETH purchase proceeds are divided between pot and reserve. Token purchase burn proceeds leave the vault immediately.

Game settlement only reallocates locked player funds and pays the prescribed fee. Draws and timeouts refund both stakes. Stakes are bounded against multiplication overflow, and the fee uses division by 20 to avoid multiplication overflow.

All paid native ETH transfers use checked calls. Token operations use vendored OpenZeppelin SafeERC20. Deposits and forwarded receipts measure actual receipt and reject a mismatch; the fixed supported tokens are assumed non-rebasing and fee-free. Tokens transferred outside the supported deposit flow remain surplus, without a rescue function.

## External calls

All vault state-changing entry points use the reentrancy guard except:

- The native `receive` entry, which accepts only the particular forwarder being swept and changes no accounting.
- The Uniswap `unlockCallback`, which requires the fixed manager and the exact single-use callback payload of an active guarded burn.

Withdrawal, purchase and game payout accounting is updated before external payments. Incoming token transfers are guarded and measured before credit. Signature checks use static calls for ERC-1271 wallets. The forwarder can only be called by the guarded vault; it has no arbitrary recipient or callback facility.

The burn callback consumes its authorization before invoking the pool. It accepts only exact ETH input consumption and positive SHIFT output meeting the minimum, clears native settlement sync state, settles exactly the input, and verifies SHIFT receipt at the fixed dead address. The output never mixes with player SHIFT. The outer call also requires the expected callback to have occurred. The fixed PoolManager and SHIFT token are external trust dependencies; neither is configurable by an administrator.

The external SHIFT hook can affect swap availability. The [verified reference hook](https://eth.blockscout.com/address/0x42ebcf86e3ab0445ba0362f911a7e8fad6ace0cc?tab=contract) checks whether trading is open; its ETH-to-SHIFT buy path returns no additional hook fee. Operations must confirm live pool/hook readiness. No vault funds are committed if the pool or hook reverts.

## Time and replay

Registration account IDs and game IDs are permanent one-use identifiers. EIP-712 binds every message to this contract and chain. Owner acceptance uses a monotonically increasing owner nonce. Relayed purchases bind their signer, purchase nonce and owner generation. ECDSA validation rejects malformed/high-s signatures; ERC-1271 authorization is checked when the transaction executes.

Rolling-cap history uses timestamp checkpoints and binary search, with no linear cleanup needed before a withdrawal or lock. Lower caps take effect immediately; increased caps and unfreezing cannot be accelerated by replacing or cancelling a schedule. Existing stakes remain locked until result settlement or timeout.

Exact time boundaries are intentional:

| Action | Boundary |
| --- | --- |
| Signed message deadline | Valid at the deadline |
| Rolling spending | A charge exactly 24 hours old no longer counts |
| Cap increase / unfreeze | Effective at 24 hours |
| Role change | Effective at 48 hours |
| Game settlement | Must precede `expiresAt + 24 hours` |
| Game refund | Allowed at `expiresAt + 24 hours` |
| Prize claim | Must precede posting time + 30 days |
| Prize expiry | Allowed at posting time + 30 days |

## Tests delivered

| Suite | Main checks |
| --- | --- |
| `Accounts.t.sol` | Both registration signatures, wrong domain, expiry, replay, ERC-1271, consented ownership, counterfactual deposits, sweep isolation, owner-only withdrawals while paused/frozen, false-return/fee tokens, reentry and rejected ETH |
| `GamesAndCaps.t.sol` | All outcomes and all assets, fee conservation, invalid locks, wrong/expired results, terminal state, timeout boundary, failed payout rollback, exact rolling windows, mixed cap changes, freeze delays, owner-change preservation, fuzz history model |
| `ShopAndBurn.t.sol` | All purchase funding modes and splits, shared caps, relayed signature tampering/replay/cancellation, odd amounts, transfer rollback, callback authentication, partial fills, slippage, reserve isolation |
| `PrizesAndRoles.t.sol` | Pot bounds, cross-asset isolation, proofs and duplicate leaves, malformed root totals, expiry, claims during pause/freeze, all role delays and replacements, old result signer rejection, restricted owner powers |
| `RealV4Integration.t.sol` | Actual vendored v4 core unlock/swap/settle/take against a local fixed-key pool, minimum-output rollback, reentrant hook attempt |
| `VaultInvariant.t.sol` | Random sequences of deposits, sweeps, withdrawal, lock/outcome/refund, owner/operator/direct shop payments, prize posting/claim/expiry, burn, time changes, caps, freeze and pause |
| `Deployment.t.sol` | Empty-chain factory constructor rehearsal, exact CREATE2 predictions, fixed owner, EIP-170/EIP-3860 limits, runtime opcode scan matching the supplied protected check |

The stateful invariants independently check account sums, all live game stakes, all epoch remainders, total liabilities versus holdings and cumulative external inflows/outflows. A deterministic handler traversal exercises the major economic transitions even when random sequences skip unavailable actions.

Validation uses the pinned compiler and assignment seed. The deployment tests do not read the protected tests' environment variables. No test uses an RPC fork, a shared environment variable, FFI or an external key.

## Remaining release responsibilities

The local core integration uses a controlled hook and token mocks; it does not simulate current production pool liquidity, token administration or all live hook states. It validates the ABI and accounting protocol, not current market execution quality. A keeper must use a meaningful `minShiftOut` and operations must verify production readiness.

Catalog pricing, item delivery, identity assignment, genuine player requests, leaderboard correctness and proof availability are service responsibilities. There is no price oracle or on-chain game engine. Pausing does not stop already authorized outcomes or withdrawals.

No Slither/Mythril run or independent audit is claimed. The deployed source verification and transaction are the launch service's responsibility.
