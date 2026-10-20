// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DepositForwarder} from "./DepositForwarder.sol";
import {IV4PoolManager} from "./interfaces/IV4PoolManager.sol";

/// @title NightshiftVault
/// @notice NIGHTSHIFT player custody, bounded operator escrow, purchases and weekly prize accounting.
/// @dev Fixed mainnet assets and beneficiaries; no upgrade, arbitrary execution or administrative withdrawal.
///      Registration authorizes the operator to act on player requests within account-controlled caps.
contract NightshiftVault is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address public constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address public constant INITIAL_ROLE = 0x3B5919586FC04F7e99b450a72bcB14Eeb6977497;
    address public constant FEE_SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    address public constant IMD_BURN_EXECUTOR = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant SHIFT_HOOK = 0x42Ebcf86E3AB0445ba0362F911a7E8FAd6aCe0CC;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint256 public constant CAP_DELAY = 24 hours;
    uint256 public constant ROLE_DELAY = 48 hours;
    uint256 public constant REFUND_DELAY = 24 hours;
    uint256 public constant CLAIM_PERIOD = 30 days;
    uint256 public constant MAX_GAME_DURATION = 24 hours;
    uint256 public constant DEFAULT_ETH_CAP = 0.05 ether;
    uint256 public constant DEFAULT_IMD_CAP = 100 ether;
    uint256 public constant DEFAULT_SHIFT_CAP = 2_500_000 ether;
    uint256 public constant DEFAULT_GAME_CAP_DIVISOR = 5;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant POOL_TICK_SPACING = 60;
    uint160 private constant MIN_SQRT_PRICE_PLUS_ONE = 4_295_128_740;

    bytes32 public constant REGISTER_TYPEHASH = keccak256("Register(bytes32 accountId,address owner,uint256 deadline)");
    bytes32 public constant OWNER_TYPEHASH =
        keccak256("SetOwner(bytes32 accountId,address owner,address newOwner,uint256 nonce,uint256 deadline)");
    bytes32 public constant RESULT_TYPEHASH = keccak256("Result(bytes32 gameId,uint8 result,uint256 deadline)");
    bytes32 public constant PURCHASE_TYPEHASH = keccak256(
        "Purchase(bytes32 accountId,bytes32 itemId,address asset,uint256 amount,address signer,uint256 nonce,uint256 ownerNonce,uint256 deadline)"
    );

    enum Role {
        Operator,
        ResultSigner,
        Keeper
    }
    enum GameStatus {
        None,
        Locked,
        Settled,
        Refunded
    }

    struct RoleChange {
        address current;
        address pending;
        uint256 readyAt;
    }

    struct Balance {
        uint256 available;
        uint256 locked;
    }

    struct Game {
        bytes32 accountA;
        bytes32 accountB;
        address asset;
        uint256 stake;
        uint256 expiresAt;
        GameStatus status;
        uint8 result;
    }

    struct CapConfig {
        bool initialized;
        uint256 daily;
        uint256 perGame;
        uint256 pendingDaily;
        uint256 pendingPerGame;
        uint256 readyAt;
    }

    struct SpendCheckpoint {
        uint256 timestamp;
        uint256 cumulative;
    }

    struct FreezeState {
        bool frozen;
        uint256 unfreezeAt;
    }

    struct Epoch {
        bytes32 root;
        uint256 total;
        uint256 remaining;
        uint256 expiresAt;
        bool expired;
    }

    mapping(bytes32 => address) public accountOf;
    mapping(bytes32 => uint256) public ownerNonces;
    mapping(bytes32 => uint256) public purchaseNonces;
    mapping(bytes32 => mapping(address => Balance)) private _balances;
    mapping(bytes32 => mapping(address => CapConfig)) private _caps;
    mapping(bytes32 => mapping(address => SpendCheckpoint[])) private _spending;
    mapping(bytes32 => FreezeState) public freezeState;
    mapping(bytes32 => Game) public games;
    mapping(Role => RoleChange) public roleChanges;
    mapping(address => uint256) public pot;
    mapping(address => uint256) public totalPlayerFunds;
    mapping(address => uint256) public reservedPrizes;
    mapping(uint256 => mapping(address => Epoch)) public epochs;
    mapping(bytes32 => bool) public claimed;
    uint256 private _burnReserve;
    bool public paused;
    address private _receivingForwarder;
    bytes32 private _burnContext;

    error Unauthorized();
    error InvalidAccount();
    error AlreadyRegistered();
    error InvalidAddress();
    error UnsupportedAsset();
    error InvalidAmount();
    error InvalidSignature();
    error DeadlineExpired();
    error IsPaused();
    error AccountFrozen();
    error InsufficientBalance();
    error CapExceeded();
    error InvalidGame();
    error InvalidResult();
    error TooEarly();
    error NoPendingChange();
    error ETHTransferFailed();
    error TransferAmountMismatch();
    error InvalidEpoch();
    error InvalidProof();
    error AlreadyClaimed();
    error InvalidCallback();
    error InvalidSwap();
    error SlippageExceeded();

    event Registered(bytes32 indexed accountId, address indexed owner);
    event OwnerSet(bytes32 indexed accountId, address indexed previousOwner, address indexed newOwner);
    event Deposited(bytes32 indexed accountId, address indexed asset, address indexed sender, uint256 amount);
    event Withdrawn(bytes32 indexed accountId, address indexed asset, address indexed owner, uint256 amount);
    event ForwarderDeployed(bytes32 indexed accountId, address indexed forwarder);
    event GameLocked(
        bytes32 indexed gameId,
        bytes32 indexed accountA,
        bytes32 indexed accountB,
        address asset,
        uint256 stake,
        uint256 expiresAt
    );
    event GameSettled(bytes32 indexed gameId, uint8 result, uint256 fee);
    event GameRefunded(bytes32 indexed gameId);
    event CapsSet(bytes32 indexed accountId, address indexed asset, uint256 daily, uint256 perGame);
    event CapsScheduled(
        bytes32 indexed accountId, address indexed asset, uint256 daily, uint256 perGame, uint256 readyAt
    );
    event CapsCancelled(bytes32 indexed accountId, address indexed asset);
    event Frozen(bytes32 indexed accountId, bool frozen, uint256 effectiveAt);
    event Purchased(bytes32 indexed accountId, bytes32 indexed itemId, address indexed asset, uint256 amount);
    event PurchaseNonceSet(bytes32 indexed accountId, uint256 nonce);
    event Burned(uint256 amountIn, uint256 shiftOut);
    event PrizesPosted(uint256 indexed epoch, bytes32 root, address indexed asset, uint256 total, uint256 expiresAt);
    event PrizeClaimed(uint256 indexed epoch, bytes32 indexed accountId, address indexed asset, uint256 amount);
    event PrizesExpired(uint256 indexed epoch, address indexed asset, uint256 returnedToPot);
    event RoleSet(Role indexed role, address indexed value);
    event RoleScheduled(Role indexed role, address indexed value, uint256 readyAt);
    event RoleCancelled(Role indexed role);
    event PauseSet(bool paused);

    /// @notice Fully configures the mainnet vault without external calls or deployer privileges.
    constructor() EIP712("NightshiftVault", "1") {
        for (uint256 i; i < 3; ++i) {
            roleChanges[Role(i)].current = INITIAL_ROLE;
            emit RoleSet(Role(i), INITIAL_ROLE);
        }
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    /// @dev Only an active sweep may deliver unlabelled ETH. Use depositETH for ordinary deposits.
    receive() external payable {
        if (msg.sender != _receivingForwarder) revert Unauthorized();
    }

    /// @notice The launch's fixed administrative owner, never the deployment factory.
    function owner() external pure returns (address) {
        return OWNER;
    }

    /// @notice The EIP-712 separator, including current chain ID and this vault's address.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Current effective account registrar, game operator and prize publisher.
    function operator() public view returns (address) {
        return _role(Role.Operator);
    }

    /// @notice Current effective authority for signed game results.
    function resultSigner() public view returns (address) {
        return _role(Role.ResultSigner);
    }

    /// @notice Current effective authority for reserve-only ETH burns.
    function keeper() public view returns (address) {
        return _role(Role.Keeper);
    }

    /// @notice Schedules an automatic role change; a replacement restarts the full 48-hour delay.
    function scheduleRoleChange(Role role, address value) external nonReentrant onlyOwner {
        if (value == address(0) || value == address(this)) revert InvalidAddress();
        roleChanges[role] = RoleChange(_role(role), value, block.timestamp + ROLE_DELAY);
        emit RoleScheduled(role, value, block.timestamp + ROLE_DELAY);
    }

    /// @notice Cancels a not-yet-effective role change.
    function cancelRoleChange(Role role) external nonReentrant onlyOwner {
        RoleChange storage change = roleChanges[role];
        if (change.readyAt == 0 || block.timestamp >= change.readyAt) revert NoPendingChange();
        change.pending = address(0);
        change.readyAt = 0;
        emit RoleCancelled(role);
    }

    /// @notice Materializes an already effective role change for indexers; anyone may call.
    function applyRoleChange(Role role) external nonReentrant {
        RoleChange storage change = roleChanges[role];
        if (change.readyAt == 0) revert NoPendingChange();
        if (block.timestamp < change.readyAt) revert TooEarly();
        change.current = change.pending;
        change.pending = address(0);
        change.readyAt = 0;
        emit RoleSet(role, change.current);
    }

    /// @notice Pauses only deposits, new game locks and purchases.
    function setPaused(bool value) external nonReentrant onlyOwner {
        paused = value;
        emit PauseSet(value);
    }

    /// @notice Registers an unused account using both the owner's and current operator's consent.
    /// @dev An account ID can never be reused; it supplies replay protection for Register.
    function register(
        bytes32 accountId,
        address accountOwner,
        uint256 deadline,
        bytes calldata ownerSig,
        bytes calldata operatorSig
    ) external nonReentrant {
        if (accountId == bytes32(0)) revert InvalidAccount();
        if (accountOwner == address(0) || accountOwner == address(this) || accountOwner == depositAddress(accountId)) {
            revert InvalidAddress();
        }
        if (accountOf[accountId] != address(0)) revert AlreadyRegistered();
        _deadline(deadline);
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(REGISTER_TYPEHASH, accountId, accountOwner, deadline)));
        _signature(accountOwner, digest, ownerSig);
        _signature(operator(), digest, operatorSig);
        accountOf[accountId] = accountOwner;
        emit Registered(accountId, accountOwner);
    }

    /// @notice Changes an account owner only when called by its current owner with the new owner's signature.
    /// @dev Preserves balances, spend history and effective caps; cancels pending cap increases and unfreezing.
    function setOwner(bytes32 accountId, address newOwner, uint256 deadline, bytes calldata newOwnerSig)
        external
        nonReentrant
    {
        address previous = _onlyAccountOwner(accountId);
        if (
            newOwner == address(0) || newOwner == address(this) || newOwner == previous
                || newOwner == depositAddress(accountId)
        ) revert InvalidAddress();
        _deadline(deadline);
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(OWNER_TYPEHASH, accountId, previous, newOwner, ownerNonces[accountId], deadline))
        );
        _signature(newOwner, digest, newOwnerSig);
        _cancelAccountChanges(accountId, address(0));
        _cancelAccountChanges(accountId, IMD);
        _cancelAccountChanges(accountId, SHIFT);
        bool isFrozen = frozen(accountId);
        freezeState[accountId] = FreezeState(isFrozen, 0);
        ++ownerNonces[accountId];
        accountOf[accountId] = newOwner;
        emit Frozen(accountId, isFrozen, block.timestamp);
        emit OwnerSet(accountId, previous, newOwner);
    }

    /// @notice Deterministic address accepting ETH and supported tokens even before deployment.
    /// @dev Register the account before funding it; an unregistered address has no withdrawal authority.
    function depositAddress(bytes32 accountId) public view returns (address) {
        // The creation code is constant and the appended constructor arguments have a fixed 64-byte length.
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(DepositForwarder).creationCode, abi.encode(address(this), accountId)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), accountId, codeHash)))));
    }

    /// @notice Deploys the personal forwarder if needed and credits its entire supported-asset balance.
    function sweep(bytes32 accountId, address asset) external nonReentrant whenNotPaused returns (uint256 amount) {
        _account(accountId);
        _asset(asset);
        address forwarder = depositAddress(accountId);
        if (forwarder.code.length == 0) {
            new DepositForwarder{salt: accountId}(address(this), accountId);
            emit ForwarderDeployed(accountId, forwarder);
        }
        uint256 beforeBalance = _holdings(asset);
        _receivingForwarder = forwarder;
        uint256 sent = DepositForwarder(payable(forwarder)).sweep(asset);
        _receivingForwarder = address(0);
        amount = _holdings(asset) - beforeBalance;
        if (amount != sent) revert TransferAmountMismatch();
        _creditDeposit(accountId, asset, amount, forwarder);
    }

    /// @notice Deposits native ETH to a registered account from any payer.
    function depositETH(bytes32 accountId) external payable nonReentrant whenNotPaused {
        _account(accountId);
        if (msg.value == 0) revert InvalidAmount();
        _creditDeposit(accountId, address(0), msg.value, msg.sender);
    }

    /// @notice Pulls exactly amount IMD or SHIFT from the caller into a registered account.
    function deposit(bytes32 accountId, address token, uint256 amount) external nonReentrant whenNotPaused {
        _account(accountId);
        _asset(token);
        if (token == address(0) || amount == 0) revert InvalidAmount();
        _pull(token, amount);
        _creditDeposit(accountId, token, amount, msg.sender);
    }

    /// @notice Withdraws available funds only to the calling account owner, even while paused or frozen.
    function withdraw(bytes32 accountId, address asset, uint256 amount) external nonReentrant {
        address recipient = _onlyAccountOwner(accountId);
        _asset(asset);
        if (amount == 0) revert InvalidAmount();
        _debit(accountId, asset, amount);
        totalPlayerFunds[asset] -= amount;
        emit Withdrawn(accountId, asset, recipient, amount);
        _send(asset, recipient, amount);
    }

    /// @notice Returns available and game-locked player funds in asset's smallest unit.
    function balanceOf(bytes32 accountId, address asset) external view returns (uint256 available, uint256 locked) {
        Balance storage balance = _balances[accountId][asset];
        return (balance.available, balance.locked);
    }

    /// @notice Returns effective daily and per-game limits, including any matured increase.
    function caps(bytes32 accountId, address asset) public view returns (uint256 daily, uint256 perGame) {
        _asset(asset);
        CapConfig storage config = _caps[accountId][asset];
        if (!config.initialized) {
            daily = asset == address(0) ? DEFAULT_ETH_CAP : asset == IMD ? DEFAULT_IMD_CAP : DEFAULT_SHIFT_CAP;
            return (daily, daily / DEFAULT_GAME_CAP_DIVISOR);
        }
        if (config.readyAt != 0 && block.timestamp >= config.readyAt) {
            return (config.pendingDaily, config.pendingPerGame);
        }
        return (config.daily, config.perGame);
    }

    /// @notice Returns stored cap configuration and any scheduled change.
    function capConfiguration(bytes32 accountId, address asset) external view returns (CapConfig memory) {
        return _caps[accountId][asset];
    }

    /// @notice Lowers either cap immediately; any requested increase takes a fresh 24 hours.
    /// @dev Every call replaces pending changes. Zero caps disable operator spending for that asset.
    function setCaps(bytes32 accountId, address asset, uint256 daily, uint256 perGame) external nonReentrant {
        _onlyAccountOwner(accountId);
        (uint256 currentDaily, uint256 currentGame) = caps(accountId, asset);
        uint256 immediateDaily = daily < currentDaily ? daily : currentDaily;
        uint256 immediateGame = perGame < currentGame ? perGame : currentGame;
        uint256 readyAt = daily > immediateDaily || perGame > immediateGame ? block.timestamp + CAP_DELAY : 0;
        _caps[accountId][asset] = CapConfig(true, immediateDaily, immediateGame, daily, perGame, readyAt);
        emit CapsSet(accountId, asset, immediateDaily, immediateGame);
        if (readyAt != 0) emit CapsScheduled(accountId, asset, daily, perGame, readyAt);
        else emit CapsCancelled(accountId, asset);
    }

    /// @notice Blocks new locks and balance purchases immediately, or schedules unfreezing in 24 hours.
    function setFrozen(bytes32 accountId, bool value) external nonReentrant {
        _onlyAccountOwner(accountId);
        if (value) {
            freezeState[accountId] = FreezeState(true, 0);
            emit Frozen(accountId, true, block.timestamp);
        } else {
            if (!frozen(accountId)) revert NoPendingChange();
            freezeState[accountId].unfreezeAt = block.timestamp + CAP_DELAY;
            emit Frozen(accountId, false, block.timestamp + CAP_DELAY);
        }
    }

    /// @notice Effective freeze state; an unfreeze becomes effective automatically at its timestamp.
    function frozen(bytes32 accountId) public view returns (bool) {
        FreezeState storage state = freezeState[accountId];
        return state.frozen && (state.unfreezeAt == 0 || block.timestamp < state.unfreezeAt);
    }

    /// @notice Exact spending in (now - 24 hours, now], including game stakes and operator purchases.
    /// @dev Binary search over cumulative checkpoints avoids an unbounded cleanup loop.
    function spentInLast24Hours(bytes32 accountId, address asset) public view returns (uint256) {
        SpendCheckpoint[] storage history = _spending[accountId][asset];
        uint256 length = history.length;
        if (length == 0) return 0;
        uint256 cumulative = history[length - 1].cumulative;
        if (block.timestamp < CAP_DELAY) return cumulative;
        uint256 cutoff = block.timestamp - CAP_DELAY;
        uint256 low = 0;
        uint256 high = length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (history[mid].timestamp <= cutoff) low = mid + 1;
            else high = mid;
        }
        return cumulative - (low == 0 ? 0 : history[low - 1].cumulative);
    }

    /// @notice Escrows equal stakes at the players' request, bounded by both accounts' limits.
    function lockGame(
        bytes32 gameId,
        bytes32 accountA,
        bytes32 accountB,
        address asset,
        uint256 stake,
        uint256 expiresAt
    ) external nonReentrant whenNotPaused {
        if (msg.sender != operator()) revert Unauthorized();
        address ownerA = _account(accountA);
        address ownerB = _account(accountB);
        _asset(asset);
        if (gameId == bytes32(0) || games[gameId].status != GameStatus.None || accountA == accountB || ownerA == ownerB)
        {
            revert InvalidGame();
        }
        if (stake == 0 || stake > type(uint256).max / 2) revert InvalidAmount();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_GAME_DURATION) revert InvalidGame();
        _checkNotFrozen(accountA);
        _checkNotFrozen(accountB);
        _consumeCap(accountA, asset, stake, true);
        _consumeCap(accountB, asset, stake, true);
        _debit(accountA, asset, stake);
        _debit(accountB, asset, stake);
        _balances[accountA][asset].locked += stake;
        _balances[accountB][asset].locked += stake;
        games[gameId] = Game(accountA, accountB, asset, stake, expiresAt, GameStatus.Locked, 0);
        emit GameLocked(gameId, accountA, accountB, asset, stake, expiresAt);
    }

    /// @notice Settles a live escrow using the current result signer's EIP-712 result.
    /// @dev Settlement is allowed through the 24-hour grace period, strictly before refund eligibility.
    function settle(bytes32 gameId, uint8 result, uint256 deadline, bytes calldata sig) external nonReentrant {
        Game storage game = games[gameId];
        if (game.status != GameStatus.Locked || block.timestamp >= game.expiresAt + REFUND_DELAY) revert InvalidGame();
        if (result > 2) revert InvalidResult();
        _deadline(deadline);
        _signature(
            resultSigner(), _hashTypedDataV4(keccak256(abi.encode(RESULT_TYPEHASH, gameId, result, deadline))), sig
        );
        game.status = GameStatus.Settled;
        game.result = result;
        _unlock(game);
        uint256 fee = 0;
        if (result == 2) {
            _refund(game);
        } else {
            uint256 gamePot = game.stake * 2;
            fee = gamePot / 20;
            _balances[result == 0 ? game.accountA : game.accountB][game.asset].available += gamePot - fee;
            totalPlayerFunds[game.asset] -= fee;
        }
        emit GameSettled(gameId, result, fee);
        if (fee != 0) _send(game.asset, FEE_SPLITTER, fee);
    }

    /// @notice Refunds both stakes permissionlessly once expiresAt + 24 hours is reached.
    function refundGame(bytes32 gameId) external nonReentrant {
        Game storage game = games[gameId];
        if (game.status != GameStatus.Locked) revert InvalidGame();
        if (block.timestamp < game.expiresAt + REFUND_DELAY) revert TooEarly();
        game.status = GameStatus.Refunded;
        _unlock(game);
        _refund(game);
        emit GameRefunded(gameId);
    }

    /// @notice Purchases using a transaction signed by the account owner or the current operator.
    function buy(bytes32 accountId, bytes32 itemId, address asset, uint256 amount) external nonReentrant whenNotPaused {
        _buy(accountId, itemId, asset, amount, msg.sender);
    }

    /// @notice Relays an owner/operator purchase signature, with nonce, owner generation and expiry.
    function buyWithSig(
        bytes32 accountId,
        bytes32 itemId,
        address asset,
        uint256 amount,
        address signer,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        _deadline(deadline);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PURCHASE_TYPEHASH,
                    accountId,
                    itemId,
                    asset,
                    amount,
                    signer,
                    purchaseNonces[accountId],
                    ownerNonces[accountId],
                    deadline
                )
            )
        );
        _signature(signer, digest, sig);
        ++purchaseNonces[accountId];
        _buy(accountId, itemId, asset, amount, signer);
    }

    /// @notice Invalidates outstanding purchase signatures for this account.
    function invalidatePurchaseNonce(bytes32 accountId, uint256 newNonce) external nonReentrant {
        _onlyAccountOwner(accountId);
        if (newNonce <= purchaseNonces[accountId]) revert InvalidAmount();
        purchaseNonces[accountId] = newNonce;
        emit PurchaseNonceSet(accountId, newNonce);
    }

    /// @notice Pays for an item from the caller's own wallet without debiting a player's balance.
    /// @dev Even raw-unit amounts ensure exact halves; the game service validates item IDs and prices.
    function buyDirect(bytes32 accountId, bytes32 itemId, address asset, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        _account(accountId);
        _purchaseAmount(asset, amount);
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            _pull(asset, amount);
        }
        _splitPurchase(accountId, itemId, asset, amount);
    }

    /// @notice ETH set aside by purchases, excluding player balances and all prize funds.
    function burnReserve() external view returns (uint256) {
        return _burnReserve;
    }

    /// @notice Swaps only reserve ETH for SHIFT on the fixed v4 pool and transfers all output to DEAD.
    /// @dev Full input consumption and a positive minimum output are mandatory; partial fills revert.
    function burnReserve(uint256 amountIn, uint256 minShiftOut) external nonReentrant returns (uint256 shiftOut) {
        if (msg.sender != keeper()) revert Unauthorized();
        if (
            amountIn == 0 || amountIn > _burnReserve || amountIn > uint256(uint128(type(int128).max))
                || minShiftOut == 0
        ) revert InvalidAmount();
        _burnReserve -= amountIn;
        bytes memory data = abi.encode(amountIn, minShiftOut);
        _burnContext = keccak256(data);
        bytes memory result = IV4PoolManager(POOL_MANAGER).unlock(data);
        if (_burnContext != bytes32(0)) revert InvalidCallback();
        shiftOut = abi.decode(result, (uint256));
        if (shiftOut < minShiftOut) revert SlippageExceeded();
        emit Burned(amountIn, shiftOut);
    }

    /// @notice Uniswap v4's authenticated, single-use callback for an in-progress reserve burn.
    /// @dev The outer burn holds the reentrancy guard; this callback is deliberately not nonReentrant.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || _burnContext == bytes32(0) || keccak256(data) != _burnContext) {
            revert InvalidCallback();
        }
        _burnContext = bytes32(0);
        (uint256 amountIn, uint256 minimum) = abi.decode(data, (uint256, uint256));
        IV4PoolManager manager = IV4PoolManager(POOL_MANAGER);
        int256 delta = manager.swap(
            IV4PoolManager.PoolKey(address(0), SHIFT, POOL_FEE, POOL_TICK_SPACING, SHIFT_HOOK),
            IV4PoolManager.SwapParams(true, -int256(amountIn), MIN_SQRT_PRICE_PLUS_ONE),
            ""
        );
        // v4 packs two signed int128 deltas: ETH in the high half, SHIFT in the low half.
        // amountIn was bounded to int128.max by the authenticated outer burn.
        int128 deltaETH = int128(delta >> 128);
        int128 deltaSHIFT = int128(delta);
        if (int256(deltaETH) != -int256(amountIn) || deltaSHIFT <= 0) revert InvalidSwap();
        uint256 output = uint256(uint128(deltaSHIFT));
        if (output < minimum) revert SlippageExceeded();
        manager.sync(address(0));
        if (manager.settle{value: amountIn}() != amountIn) revert InvalidSwap();
        uint256 beforeBalance = IERC20(SHIFT).balanceOf(DEAD);
        manager.take(SHIFT, DEAD, output);
        if (IERC20(SHIFT).balanceOf(DEAD) - beforeBalance != output) revert TransferAmountMismatch();
        return abi.encode(output);
    }

    /// @notice Reserves an asset's pot for a single immutable weekly prize root.
    /// @dev Epoch identifiers are assigned by the leaderboard service; one posting per epoch/asset forever.
    function postPrizes(uint256 epoch, bytes32 root, address asset, uint256 total) external nonReentrant {
        if (msg.sender != operator()) revert Unauthorized();
        _asset(asset);
        if (root == bytes32(0) || epochs[epoch][asset].expiresAt != 0) revert InvalidEpoch();
        if (total == 0 || total > pot[asset]) revert InvalidAmount();
        pot[asset] -= total;
        reservedPrizes[asset] += total;
        epochs[epoch][asset] = Epoch(root, total, total, block.timestamp + CLAIM_PERIOD, false);
        emit PrizesPosted(epoch, root, asset, total, block.timestamp + CLAIM_PERIOD);
    }

    /// @notice Credits a StandardMerkleTree prize leaf to its account; anyone may relay its proof.
    function claimPrize(uint256 epoch, bytes32 accountId, address asset, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        _account(accountId);
        _asset(asset);
        Epoch storage distribution = epochs[epoch][asset];
        if (distribution.expiresAt == 0 || distribution.expired || block.timestamp >= distribution.expiresAt) {
            revert InvalidEpoch();
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(epoch, accountId, asset, amount))));
        if (claimed[leaf]) revert AlreadyClaimed();
        if (amount == 0 || amount > distribution.remaining) revert InvalidAmount();
        if (!MerkleProof.verifyCalldata(proof, distribution.root, leaf)) revert InvalidProof();
        claimed[leaf] = true;
        distribution.remaining -= amount;
        reservedPrizes[asset] -= amount;
        totalPlayerFunds[asset] += amount;
        _balances[accountId][asset].available += amount;
        emit PrizeClaimed(epoch, accountId, asset, amount);
    }

    /// @notice Returns all unclaimed funds to the same asset's pot after 30 days.
    function expirePrizes(uint256 epoch, address asset) external nonReentrant {
        _asset(asset);
        Epoch storage distribution = epochs[epoch][asset];
        if (distribution.expiresAt == 0 || distribution.expired) revert InvalidEpoch();
        if (block.timestamp < distribution.expiresAt) revert TooEarly();
        uint256 remaining = distribution.remaining;
        distribution.remaining = 0;
        distribution.expired = true;
        reservedPrizes[asset] -= remaining;
        pot[asset] += remaining;
        emit PrizesExpired(epoch, asset, remaining);
    }

    /// @notice Total accounted liabilities; unsolicited transfers remain unallocated and cannot be rescued.
    function accountedHoldings(address asset) external view returns (uint256) {
        _asset(asset);
        return totalPlayerFunds[asset] + pot[asset] + reservedPrizes[asset] + (asset == address(0) ? _burnReserve : 0);
    }

    function _role(Role role) private view returns (address) {
        RoleChange storage change = roleChanges[role];
        return change.readyAt != 0 && block.timestamp >= change.readyAt ? change.pending : change.current;
    }

    function _account(bytes32 accountId) private view returns (address value) {
        value = accountOf[accountId];
        if (value == address(0)) revert InvalidAccount();
    }

    function _onlyAccountOwner(bytes32 accountId) private view returns (address value) {
        value = _account(accountId);
        if (msg.sender != value) revert Unauthorized();
    }

    function _asset(address asset) private pure {
        if (asset != address(0) && asset != IMD && asset != SHIFT) revert UnsupportedAsset();
    }

    function _deadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _signature(address signer, bytes32 digest, bytes calldata sig) private view {
        if (signer == address(0) || !SignatureChecker.isValidSignatureNow(signer, digest, sig)) {
            revert InvalidSignature();
        }
    }

    function _checkNotFrozen(bytes32 accountId) private view {
        if (frozen(accountId)) revert AccountFrozen();
    }

    function _cancelAccountChanges(bytes32 accountId, address asset) private {
        (uint256 daily, uint256 perGame) = caps(accountId, asset);
        _caps[accountId][asset] = CapConfig(true, daily, perGame, 0, 0, 0);
        emit CapsCancelled(accountId, asset);
    }

    function _creditDeposit(bytes32 accountId, address asset, uint256 amount, address sender) private {
        _balances[accountId][asset].available += amount;
        totalPlayerFunds[asset] += amount;
        emit Deposited(accountId, asset, sender, amount);
    }

    function _debit(bytes32 accountId, address asset, uint256 amount) private {
        Balance storage balance = _balances[accountId][asset];
        if (amount > balance.available) revert InsufficientBalance();
        balance.available -= amount;
    }

    function _holdings(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _pull(address asset, uint256 amount) private {
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(asset).balanceOf(address(this)) - beforeBalance != amount) revert TransferAmountMismatch();
    }

    function _send(address asset, address recipient, uint256 amount) private {
        if (asset == address(0)) {
            (bool ok,) = payable(recipient).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
    }

    function _consumeCap(bytes32 accountId, address asset, uint256 amount, bool game) private {
        (uint256 daily, uint256 perGame) = caps(accountId, asset);
        uint256 spent = spentInLast24Hours(accountId, asset);
        if ((game && amount > perGame) || amount > daily || spent > daily - amount) revert CapExceeded();
        SpendCheckpoint[] storage history = _spending[accountId][asset];
        uint256 length = history.length;
        uint256 cumulative = amount + (length == 0 ? 0 : history[length - 1].cumulative);
        if (length != 0 && history[length - 1].timestamp == block.timestamp) {
            history[length - 1].cumulative = cumulative;
        } else {
            history.push(SpendCheckpoint(block.timestamp, cumulative));
        }
    }

    function _unlock(Game storage game) private {
        _balances[game.accountA][game.asset].locked -= game.stake;
        _balances[game.accountB][game.asset].locked -= game.stake;
    }

    function _refund(Game storage game) private {
        _balances[game.accountA][game.asset].available += game.stake;
        _balances[game.accountB][game.asset].available += game.stake;
    }

    function _purchaseAmount(address asset, uint256 amount) private pure {
        _asset(asset);
        if (amount == 0 || amount % 2 != 0) revert InvalidAmount();
    }

    function _buy(bytes32 accountId, bytes32 itemId, address asset, uint256 amount, address signer) private {
        address accountOwner = _account(accountId);
        if (signer != accountOwner && signer != operator()) revert Unauthorized();
        _checkNotFrozen(accountId);
        _purchaseAmount(asset, amount);
        if (signer != accountOwner) _consumeCap(accountId, asset, amount, false);
        _debit(accountId, asset, amount);
        totalPlayerFunds[asset] -= amount;
        _splitPurchase(accountId, itemId, asset, amount);
    }

    function _splitPurchase(bytes32 accountId, bytes32 itemId, address asset, uint256 amount) private {
        uint256 half = amount / 2;
        pot[asset] += half;
        if (asset == address(0)) _burnReserve += half;
        emit Purchased(accountId, itemId, asset, amount);
        if (asset != address(0)) _send(asset, asset == IMD ? IMD_BURN_EXECUTOR : DEAD, half);
    }
}
