// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExile} from "./interfaces/IExile.sol";

/// @title Exile
/// @notice Time locks for ERC-20s (including v2 LP tokens), ERC-721s and ERC-1155s, plus tiered
/// holder rewards for ERC-20 locks.
///
/// Locks can be extended but never shortened, cancelled or transferred. No fees.
///
/// Rewards: a reward pool is attached to one stake token. Each lock earns points =
/// amount x tier multiplier, where the tier is picked by lock length. A pool pays two streams on
/// the same points: its reward token (deposits from `notifyReward`) and the stake token itself
/// (deposits from `notifyStakeReward`, for a Lodestar that sends its token-side fees to lockers).
/// Each deposit drips out evenly over 3 days and is shared every second by points, so locking
/// right before a payout only catches a sliver of it. A lock stops earning exactly at its unlock
/// time: unlock times are rounded up to the hour, points expiring in each hour are tracked in a
/// bucket, and the pool removes them as it passes each hour boundary.
///
/// A pool's reward token can be native HYPE (address(0)), which is how fees arrive on the v4 launchpads.
///
/// Harvest: coins on those launchpads can pay their holders HYPE dividends by balance, and Exile's balance earns
/// them for every locked coin. For a token whose harvest is set, anyone can call `harvest(token)`: Exile claims
/// those dividends for itself and pays what arrives to the token's harvest pool, where it drips to lockers like
/// any other reward. HYPE a token pushes to Exile on its own (a permissionless claim made for Exile) is counted per
/// sender and joins that token's next harvest. Only registrars (Monarchy's factories, added by the owner behind a
/// 12 hour timelock) name harvest pools, and the call has one of three fixed shapes, never with value:
/// `claimFor(exile)`, `claimRewards(exile)` (Kleos) or `claim()` (ElysPump) on the token itself, or
/// `claimRewards(token, exile)` on the token's hook (Boxa). The owner can never move a locked token or a reward.
contract Exile is IExile, ReentrancyGuard, IERC721Receiver, IERC1155Receiver {
    using SafeERC20 for IERC20;

    enum Kind {
        ERC20,
        ERC721,
        ERC1155
    }

    /// @dev One reward stream. Stream 0 pays the pool's reward token, stream 1 the stake token.
    struct Stream {
        uint64 periodFinish;
        uint256 rewardPerPoint; // scaled by ACC_PREC * RATE_PREC
        uint256 rewardRate; // reward units per second, scaled by RATE_PREC
        uint256 unallocated; // dripped while nobody was locked, scaled by RATE_PREC
        uint256 totalDistributed;
        mapping(uint64 => uint256) rppAtBucket;
    }

    struct Pool {
        address stakeToken;
        address rewardToken;
        address admin;
        uint64 tiersEta;
        uint64 lastUpdate;
        uint64 cursor; // last processed hour boundary
        uint256 totalPoints;
        Tier[] tiers;
        Tier[] pendingTiers;
        mapping(uint64 => uint256) pointsExpiring;
        Stream[2] streams;
    }

    struct Lock {
        address owner;
        Kind kind;
        bool withdrawn;
        uint16 multiplierBps;
        uint64 createdAt;
        uint64 unlockAt;
        address asset;
        uint256 tokenId;
        uint256 amount;
        uint256 poolId; // 0 = no rewards
        uint256 points;
        uint256 rewardPerPointPaid;
        uint256 rewardsAccrued;
        uint256 stakeRewardPerPointPaid; // the same, for rewards paid in the stake token
        uint256 stakeRewardsAccrued;
    }

    struct PoolView {
        address stakeToken;
        address rewardToken;
        address admin;
        uint256 totalPoints;
        uint256 rewardRate;
        uint64 periodFinish;
        uint64 tiersEta;
        uint256 totalDistributed;
        Tier[] tiers;
        Tier[] pendingTiers;
        uint256 carry; // rewards that dripped while nobody was locked; they re-drip with the next payout
        // the stake-token stream, same meanings
        uint256 stakeRewardRate;
        uint64 stakePeriodFinish;
        uint256 stakeTotalDistributed;
        uint256 stakeCarry;
    }

    uint64 public constant BUCKET = 1 hours;
    uint64 public constant DRIP = 3 days;
    uint64 public constant TIMELOCK = 12 hours;
    /// @dev A ready tier change must be executed within this window, or proposed again.
    uint64 public constant EXECUTION_WINDOW = 7 days;
    /// @dev How many hourly buckets one action catches up. An idle hour costs a few thousand gas, but an hour
    /// in which points expire snapshots both streams (about 47k), so at most MAX_EXPIRING_PER_CALL of those
    /// fit in one lock, claim, extend, withdraw or poke. Together that stays under about 17M gas, well inside
    /// a 32M transaction. Payouts (`notifyReward`, `notifyStakeReward`) catch up without either cap.
    uint256 public constant MAX_BUCKETS_PER_CALL = 720;
    uint256 public constant MAX_EXPIRING_PER_CALL = 300;
    uint256 public constant MAX_TIERS = 8;
    /// @dev Bounds on what a tier can promise, so a pool admin can't add a tier that earns several times a
    /// 30 day lock's weight for a commitment of seconds. A tier can't be shorter than one bucket.
    uint16 public constant MAX_MULTIPLIER_BPS = 50_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RATE_PREC = 1e18;
    uint256 internal constant ACC_PREC = 1e18;
    uint256 internal constant REWARD = 0; // stream paid in the pool's reward token
    uint256 internal constant STAKE = 1; // stream paid in the stake token
    /// @dev The dividend claims a harvest may call. On the stake token, as `selector(address(this))`: a coin's
    /// `claimFor(holder)` (no supported launchpad uses it today) and Kleos coins' `claimRewards(holder)`; or with no argument, ElysPump coins' `claim()`,
    /// which pays the caller. On another contract (the coin's hook), as `selector(stakeToken, address(this))`: Boxa
    /// hooks' `claimRewards(token, recipient)`, which pays the caller's dividends in that token to the recipient.
    bytes4 internal constant CLAIM_FOR = bytes4(keccak256("claimFor(address)"));
    bytes4 internal constant CLAIM_REWARDS_FOR = bytes4(keccak256("claimRewards(address)"));
    bytes4 internal constant CLAIM = bytes4(keccak256("claim()"));
    bytes4 internal constant CLAIM_REWARDS_TO = bytes4(keccak256("claimRewards(address,address)"));

    struct Harvest {
        uint256 poolId;
        address target; // the stake token, or the hook that pays its holders
        bytes4 selector;
    }

    uint256 public poolCount;
    mapping(uint256 => Pool) internal _pools;
    mapping(address => uint256[]) internal _poolsOf;

    uint256 public lockCount;
    mapping(uint256 => Lock) internal _locks;
    mapping(address => uint256[]) internal _lockIdsOf;

    bool internal _pulling;

    /// @notice Adds registrars (behind a 12 hour timelock) and removes them; nothing else. A multisig on live chains.
    address public owner;
    address public pendingOwner;
    /// @notice Contracts that may name a token's harvest pool: Monarchy's Lodestar factories.
    mapping(address => bool) public isRegistrar;
    /// @notice When a proposed registrar can be added (0 = none proposed).
    mapping(address => uint64) public registrarEta;
    /// @notice The native pool that receives the HYPE dividends locks of a token earn, and the token's claim.
    mapping(address stakeToken => Harvest) public harvestOf;
    /// @notice HYPE that reached Exile from an address outside a harvest call, waiting for that address's next
    /// harvest (a token pushing a holder payout to Exile on its own).
    mapping(address from => uint256) public unattributed;
    /// @dev The token being harvested right now; HYPE arriving meanwhile is the harvest's own.
    address internal transient _harvesting;

    event PoolCreated(uint256 indexed poolId, address indexed stakeToken, address rewardToken, address admin);
    event Locked(
        uint256 indexed lockId,
        address indexed owner,
        Kind kind,
        address indexed asset,
        uint256 tokenId,
        uint256 amount,
        uint64 unlockAt,
        uint256 poolId,
        uint16 multiplierBps,
        uint256 points
    );
    event Extended(uint256 indexed lockId, uint64 oldUnlockAt, uint64 newUnlockAt, uint16 multiplierBps, uint256 points);
    event Withdrawn(uint256 indexed lockId, address indexed owner);
    event RewardAdded(uint256 indexed poolId, address indexed from, uint256 amount, uint256 rewardRate, uint64 periodFinish);
    event RewardsClaimed(uint256 indexed lockId, address indexed to, uint256 amount);
    event StakeRewardAdded(
        uint256 indexed poolId, address indexed from, uint256 amount, uint256 rewardRate, uint64 periodFinish
    );
    event StakeRewardsClaimed(uint256 indexed lockId, address indexed to, uint256 amount);
    event TiersProposed(uint256 indexed poolId, uint64 eta);
    event TiersExecuted(uint256 indexed poolId);
    event TiersCancelled(uint256 indexed poolId);
    event OwnerTransferStarted(address indexed next);
    event OwnerTransferred(address indexed previous, address indexed next);
    event RegistrarProposed(address indexed registrar, uint64 eta);
    event RegistrarAdded(address indexed registrar);
    event RegistrarRemoved(address indexed registrar);
    event HarvestSet(address indexed stakeToken, uint256 indexed poolId, address target, bytes4 selector);
    event Harvested(address indexed stakeToken, uint256 indexed poolId, uint256 amount, bool claimed);
    event NativeReceived(address indexed from, uint256 amount);

    error UnknownPool();
    error UnknownLock();
    error InvalidTiers();
    error InvalidAmount();
    error InvalidUnlock();
    error WrongStakeToken();
    error NotOwner();
    error NotAdmin();
    error StillLocked();
    error AlreadyWithdrawn();
    error NotExtending();
    error NoPendingTiers();
    error TimelockActive();
    error PoolNeedsPoke();
    error ProposalExpired();
    error UnexpectedNFT();
    error NotAnERC20();
    error ZeroAddress();
    error WrongValue();
    error PayoutFailed();
    error OnlyOwner();
    error NotPendingOwner();
    error NotRegistrar();
    error NoPendingRegistrar();
    error InvalidHarvest();
    error NoHarvest();
    error HarvestPoolOnly();

    constructor() {
        owner = msg.sender;
        emit OwnerTransferred(address(0), msg.sender);
    }

    // ================================================================ pools

    /// @inheritdoc IExile
    function createPool(address stakeToken, address rewardToken, Tier[] calldata tiers, address admin)
        external
        returns (uint256 poolId)
    {
        // rewardToken == address(0) makes a native HYPE pool
        if (stakeToken == address(0) || admin == address(0)) revert InvalidTiers();
        _validateTiers(tiers);
        poolId = ++poolCount;
        Pool storage p = _pools[poolId];
        p.stakeToken = stakeToken;
        p.rewardToken = rewardToken;
        p.admin = admin;
        p.cursor = _floorBucket(block.timestamp);
        p.lastUpdate = uint64(block.timestamp);
        p.streams[REWARD].periodFinish = uint64(block.timestamp);
        p.streams[STAKE].periodFinish = uint64(block.timestamp);
        for (uint256 i; i < tiers.length; ++i) {
            p.tiers.push(tiers[i]);
        }
        _poolsOf[stakeToken].push(poolId);
        emit PoolCreated(poolId, stakeToken, rewardToken, admin);
    }

    /// @inheritdoc IExile
    function notifyReward(uint256 poolId, uint256 amount) external payable nonReentrant {
        Pool storage p = _pool(poolId);
        uint256 received;
        if (p.rewardToken == address(0)) {
            if (msg.value != amount) revert WrongValue();
            received = amount;
        } else {
            if (msg.value != 0) revert WrongValue();
            received = _pullERC20(p.rewardToken, amount);
        }
        (uint256 rate, uint64 finish) = _notify(p, REWARD, received);
        emit RewardAdded(poolId, msg.sender, received, rate, finish);
    }

    /// @inheritdoc IExile
    function notifyStakeReward(uint256 poolId, uint256 amount) external nonReentrant {
        Pool storage p = _pool(poolId);
        uint256 received = _pullERC20(p.stakeToken, amount);
        (uint256 rate, uint64 finish) = _notify(p, STAKE, received);
        emit StakeRewardAdded(poolId, msg.sender, received, rate, finish);
    }

    // ================================================================ harvest

    /// @inheritdoc IExile
    function setHarvest(address stakeToken, uint256 poolId, address target, bytes4 selector) external {
        if (!isRegistrar[msg.sender]) revert NotRegistrar();
        Pool storage p = _pool(poolId);
        if (p.stakeToken != stakeToken || p.rewardToken != address(0)) revert InvalidHarvest();
        if (selector == CLAIM_FOR || selector == CLAIM_REWARDS_FOR || selector == CLAIM) {
            if (target != stakeToken) revert InvalidHarvest();
        } else if (selector == CLAIM_REWARDS_TO) {
            if (target == stakeToken || target.code.length == 0) revert InvalidHarvest();
        } else {
            revert InvalidHarvest();
        }
        harvestOf[stakeToken] = Harvest(poolId, target, selector);
        emit HarvestSet(stakeToken, poolId, target, selector);
    }

    /// @inheritdoc IExile
    /// @dev Anyone may call it; the keeper runs it with every distribute. A claim that reverts (nothing owed, a
    /// paused token) still pays out whatever the token pushed to Exile on its own since the last harvest.
    function harvest(address stakeToken) external nonReentrant returns (uint256 amount) {
        Harvest memory h = harvestOf[stakeToken];
        if (h.poolId == 0) revert NoHarvest();
        uint256 before = address(this).balance;
        _harvesting = stakeToken;
        bytes memory data = h.selector == CLAIM
            ? abi.encodeWithSelector(CLAIM)
            : h.target == stakeToken
                ? abi.encodeWithSelector(h.selector, address(this))
                : abi.encodeWithSelector(h.selector, stakeToken, address(this));
        (bool claimed,) = h.target.call(data);
        _harvesting = address(0);
        // nothing in a claim can take HYPE out of Exile: every payout path is nonReentrant
        amount = address(this).balance - before + unattributed[stakeToken];
        if (amount == 0) return 0;
        unattributed[stakeToken] = 0;
        Pool storage p = _pools[h.poolId];
        (uint256 rate, uint64 finish) = _notify(p, REWARD, amount);
        emit RewardAdded(h.poolId, stakeToken, amount, rate, finish);
        emit Harvested(stakeToken, h.poolId, amount, claimed);
    }

    /// @notice HYPE outside `notifyReward`: a harvest's own claim, or a token paying out to Exile on its own,
    /// which is set aside for that token's next harvest. Anything else sent here stays here.
    receive() external payable {
        if (_harvesting != address(0)) return;
        unattributed[msg.sender] += msg.value;
        emit NativeReceived(msg.sender, msg.value);
    }

    // ================================================================ owner

    /// @notice Propose a registrar. It can be added by anyone 12 hours later, within the 7 days after that.
    function proposeRegistrar(address registrar) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (registrar == address(0)) revert ZeroAddress();
        uint64 eta = uint64(block.timestamp) + TIMELOCK;
        registrarEta[registrar] = eta;
        emit RegistrarProposed(registrar, eta);
    }

    function addRegistrar(address registrar) external {
        uint64 eta = registrarEta[registrar];
        if (eta == 0) revert NoPendingRegistrar();
        if (block.timestamp < eta) revert TimelockActive();
        if (block.timestamp > eta + EXECUTION_WINDOW) revert ProposalExpired();
        delete registrarEta[registrar];
        isRegistrar[registrar] = true;
        emit RegistrarAdded(registrar);
    }

    /// @notice Remove a registrar or drop a proposed one, at once. Harvest pools it already named stay.
    function removeRegistrar(address registrar) external {
        if (msg.sender != owner) revert OnlyOwner();
        delete registrarEta[registrar];
        isRegistrar[registrar] = false;
        emit RegistrarRemoved(registrar);
    }

    /// @notice Start handing the owner role to `next`, which takes it with `acceptOwner` (0 cancels).
    function transferOwner(address next) external {
        if (msg.sender != owner) revert OnlyOwner();
        pendingOwner = next;
        emit OwnerTransferStarted(next);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ================================================================ pools (continued)

    /// @notice Process up to `maxBuckets` hour boundaries for a pool that has been idle a long time.
    function poke(uint256 poolId, uint256 maxBuckets) external returns (bool caughtUp) {
        return _updatePool(_pool(poolId), maxBuckets, MAX_EXPIRING_PER_CALL, false);
    }

    function proposeTiers(uint256 poolId, Tier[] calldata tiers) external {
        Pool storage p = _pool(poolId);
        if (msg.sender != p.admin) revert NotAdmin();
        _validateTiers(tiers);
        delete p.pendingTiers;
        for (uint256 i; i < tiers.length; ++i) {
            p.pendingTiers.push(tiers[i]);
        }
        p.tiersEta = uint64(block.timestamp + TIMELOCK);
        emit TiersProposed(poolId, p.tiersEta);
    }

    function executeTiers(uint256 poolId) external {
        Pool storage p = _pool(poolId);
        if (p.tiersEta == 0) revert NoPendingTiers();
        if (block.timestamp < p.tiersEta) revert TimelockActive();
        if (block.timestamp > p.tiersEta + EXECUTION_WINDOW) revert ProposalExpired();
        delete p.tiers;
        for (uint256 i; i < p.pendingTiers.length; ++i) {
            p.tiers.push(p.pendingTiers[i]);
        }
        delete p.pendingTiers;
        p.tiersEta = 0;
        emit TiersExecuted(poolId);
    }

    function cancelTiers(uint256 poolId) external {
        Pool storage p = _pool(poolId);
        if (msg.sender != p.admin) revert NotAdmin();
        if (p.tiersEta == 0) revert NoPendingTiers();
        delete p.pendingTiers;
        p.tiersEta = 0;
        emit TiersCancelled(poolId);
    }

    // ================================================================ locks

    /// @notice Lock ERC-20 tokens until `unlockAt` (rounded up to the hour). Pass a reward pool id to earn
    /// that pool's rewards, or 0 for a plain lock. A coin with a harvest only takes locks in its harvest pool.
    function lockERC20(address asset, uint256 amount, uint64 unlockAt, uint256 poolId)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (amount == 0) revert InvalidAmount();
        if (unlockAt <= block.timestamp) revert InvalidUnlock();
        if (poolId != 0 && _pool(poolId).stakeToken != asset) revert WrongStakeToken();
        // a coin with a harvest pays dividends on all of Exile's balance of it, and the harvest gives them all to
        // one pool, so a plain lock or a lock in another pool would earn them for that pool's lockers
        uint256 harvestPool = harvestOf[asset].poolId;
        if (harvestPool != 0 && poolId != harvestPool) revert HarvestPoolOnly();
        // an NFT collection pasted into the token path would be pulled with transferFrom(from, to, id) and
        // could never be withdrawn, so refuse anything that says it is ERC-721
        (bool isNft, bytes memory ret) =
            asset.staticcall{gas: 30_000}(abi.encodeCall(IERC165.supportsInterface, (type(IERC721).interfaceId)));
        if (isNft && ret.length == 32 && bytes32(ret) == bytes32(uint256(1))) revert NotAnERC20();

        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert InvalidAmount();

        lockId = _newLock(Kind.ERC20, asset, 0, received, unlockAt);
        Lock storage l = _locks[lockId];
        if (poolId != 0) {
            // A lock shorter than the first tier joins the pool with zero points, so extending it
            // later can still earn.
            Pool storage p = _pools[poolId];
            _updatePool(p, MAX_BUCKETS_PER_CALL, MAX_EXPIRING_PER_CALL, true);
            uint16 mult = _tierMultiplier(p.tiers, unlockAt - block.timestamp);
            l.poolId = poolId;
            l.multiplierBps = mult;
            l.points = received * mult / BPS;
            l.rewardPerPointPaid = p.streams[REWARD].rewardPerPoint;
            l.stakeRewardPerPointPaid = p.streams[STAKE].rewardPerPoint;
            p.totalPoints += l.points;
            p.pointsExpiring[l.unlockAt] += l.points;
        }
        emit Locked(lockId, msg.sender, Kind.ERC20, asset, 0, received, l.unlockAt, l.poolId, l.multiplierBps, l.points);
    }

    function lockERC721(address asset, uint256 tokenId, uint64 unlockAt) external nonReentrant returns (uint256 lockId) {
        if (unlockAt <= block.timestamp) revert InvalidUnlock();
        _pulling = true;
        IERC721(asset).safeTransferFrom(msg.sender, address(this), tokenId);
        _pulling = false;
        lockId = _newLock(Kind.ERC721, asset, tokenId, 1, unlockAt);
        emit Locked(lockId, msg.sender, Kind.ERC721, asset, tokenId, 1, _locks[lockId].unlockAt, 0, 0, 0);
    }

    function lockERC1155(address asset, uint256 id, uint256 amount, uint64 unlockAt)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (amount == 0) revert InvalidAmount();
        if (unlockAt <= block.timestamp) revert InvalidUnlock();
        _pulling = true;
        IERC1155(asset).safeTransferFrom(msg.sender, address(this), id, amount, "");
        _pulling = false;
        lockId = _newLock(Kind.ERC1155, asset, id, amount, unlockAt);
        emit Locked(lockId, msg.sender, Kind.ERC1155, asset, id, amount, _locks[lockId].unlockAt, 0, 0, 0);
    }

    /// @notice Push the unlock time later. The lock is re-tiered from now to the new unlock time, so the
    /// multiplier always matches what is still committed: keeping Monarch means keeping 30 days ahead,
    /// and a past long lock can't hold 3x through one-hour extensions.
    function extend(uint256 lockId, uint64 newUnlockAt) external nonReentrant {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert NotOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        uint64 rounded = _ceilBucket(newUnlockAt);
        if (newUnlockAt <= block.timestamp || rounded <= l.unlockAt) revert NotExtending();
        uint64 oldUnlock = l.unlockAt;

        if (l.poolId != 0) {
            Pool storage p = _pools[l.poolId];
            _settle(p, l);
            if (oldUnlock > p.cursor) {
                // points still live: move them out of the old bucket
                p.pointsExpiring[oldUnlock] -= l.points;
                p.totalPoints -= l.points;
            }
            uint16 tierMult = _tierMultiplier(p.tiers, newUnlockAt - block.timestamp);
            l.multiplierBps = tierMult;
            l.points = l.amount * l.multiplierBps / BPS;
            l.unlockAt = rounded;
            l.rewardPerPointPaid = p.streams[REWARD].rewardPerPoint;
            l.stakeRewardPerPointPaid = p.streams[STAKE].rewardPerPoint;
            p.totalPoints += l.points;
            p.pointsExpiring[rounded] += l.points;
        } else {
            l.unlockAt = rounded;
        }
        emit Extended(lockId, oldUnlock, rounded, l.multiplierBps, l.points);
    }

    function withdraw(uint256 lockId) external nonReentrant {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert NotOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockAt) revert StillLocked();
        if (l.poolId != 0) _settle(_pools[l.poolId], l);
        l.withdrawn = true;

        if (l.kind == Kind.ERC20) {
            IERC20(l.asset).safeTransfer(l.owner, l.amount);
        } else if (l.kind == Kind.ERC721) {
            IERC721(l.asset).transferFrom(address(this), l.owner, l.tokenId);
        } else {
            IERC1155(l.asset).safeTransferFrom(address(this), l.owner, l.tokenId, l.amount, "");
        }
        emit Withdrawn(lockId, l.owner);
    }

    function claimRewards(uint256 lockId) public nonReentrant returns (uint256 amount) {
        amount = _claim(lockId, msg.sender);
    }

    /// @notice Claim to another address, for an owner the reward token won't pay (a blocklisted wallet).
    function claimRewardsTo(uint256 lockId, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = _claim(lockId, to);
    }

    /// @notice Claim only the stake-token rewards, for when the reward token can't be paid out right now (paused,
    /// or refusing every recipient), so it can't hold the other stream hostage. Returns the stake-token amount.
    function claimStakeRewardsTo(uint256 lockId, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert NotOwner();
        if (l.poolId == 0) return 0;
        Pool storage p = _pools[l.poolId];
        _settle(p, l);
        amount = _payStake(p, l, lockId, to);
    }

    /// @notice Claim only the reward-token rewards, the mirror of `claimStakeRewardsTo`: for when the stake token
    /// can't be paid out right now (paused), so it can't hold the reward token hostage. Returns the reward-token amount.
    function claimRewardTokenTo(uint256 lockId, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert NotOwner();
        if (l.poolId == 0) return 0;
        Pool storage p = _pools[l.poolId];
        _settle(p, l);
        amount = _payReward(p, l, lockId, to);
    }

    function claimRewardsBatch(uint256[] calldata lockIds) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < lockIds.length; ++i) {
            total += _claim(lockIds[i], msg.sender);
        }
    }

    // ================================================================ views

    /// @notice Reward-token rewards a lock could claim right now, including anything not yet checkpointed.
    function pendingRewards(uint256 lockId) external view returns (uint256) {
        Lock storage l = _lock(lockId);
        if (l.poolId == 0) return 0;
        return l.rewardsAccrued + _pendingFor(_pools[l.poolId], REWARD, l, l.rewardPerPointPaid);
    }

    /// @notice Stake-token rewards a lock could claim right now (token-side fees a Lodestar sends to lockers).
    function pendingStakeRewards(uint256 lockId) external view returns (uint256) {
        Lock storage l = _lock(lockId);
        if (l.poolId == 0) return 0;
        return l.stakeRewardsAccrued + _pendingFor(_pools[l.poolId], STAKE, l, l.stakeRewardPerPointPaid);
    }

    /// @notice Current reward-token flow to a lock, in reward units per second scaled by 1e18. Used for
    /// the ticking counter in the UI.
    function earningRatePerSecond(uint256 lockId) external view returns (uint256) {
        return _ratePerSecond(lockId, REWARD);
    }

    /// @notice Current stake-token flow to a lock, in token units per second scaled by 1e18.
    function stakeEarningRatePerSecond(uint256 lockId) external view returns (uint256) {
        return _ratePerSecond(lockId, STAKE);
    }

    function tierFor(uint256 poolId, uint256 duration) external view returns (uint16 multiplierBps, bytes32 label) {
        Tier[] storage tiers = _pool(poolId).tiers;
        for (uint256 i = tiers.length; i > 0; --i) {
            if (tiers[i - 1].minDuration <= duration) {
                return (tiers[i - 1].multiplierBps, tiers[i - 1].label);
            }
        }
        return (0, bytes32(0));
    }

    function poolInfo(uint256 poolId) external view returns (PoolView memory v) {
        Pool storage p = _pool(poolId);
        (,,, uint256 totalPoints, uint256 carry) = _simulateFull(p, REWARD, 0);
        (,,,, uint256 stakeCarry) = _simulateFull(p, STAKE, 0);
        Stream storage r = p.streams[REWARD];
        Stream storage k = p.streams[STAKE];
        v.stakeToken = p.stakeToken;
        v.rewardToken = p.rewardToken;
        v.admin = p.admin;
        v.totalPoints = totalPoints;
        v.rewardRate = block.timestamp < r.periodFinish ? r.rewardRate : 0;
        v.periodFinish = r.periodFinish;
        v.tiersEta = p.tiersEta;
        v.totalDistributed = r.totalDistributed;
        v.tiers = p.tiers;
        v.pendingTiers = p.pendingTiers;
        v.carry = carry / RATE_PREC;
        v.stakeRewardRate = block.timestamp < k.periodFinish ? k.rewardRate : 0;
        v.stakePeriodFinish = k.periodFinish;
        v.stakeTotalDistributed = k.totalDistributed;
        v.stakeCarry = stakeCarry / RATE_PREC;
    }

    function lockInfo(uint256 lockId) external view returns (Lock memory) {
        return _lock(lockId);
    }

    function lockIdsOf(address holder) external view returns (uint256[] memory) {
        return _lockIdsOf[holder];
    }

    function poolsOf(address stakeToken) external view returns (uint256[] memory) {
        return _poolsOf[stakeToken];
    }

    // ================================================================ receivers

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (!_pulling) revert UnexpectedNFT();
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (!_pulling) revert UnexpectedNFT();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnexpectedNFT();
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // ================================================================ internals

    function _newLock(Kind kind, address asset, uint256 tokenId, uint256 amount, uint64 unlockAt)
        internal
        returns (uint256 lockId)
    {
        lockId = ++lockCount;
        Lock storage l = _locks[lockId];
        l.owner = msg.sender;
        l.kind = kind;
        l.asset = asset;
        l.tokenId = tokenId;
        l.amount = amount;
        l.createdAt = uint64(block.timestamp);
        l.unlockAt = _ceilBucket(unlockAt);
        _lockIdsOf[msg.sender].push(lockId);
    }

    function _pullERC20(address asset, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) revert InvalidAmount();
        IERC20 rt = IERC20(asset);
        uint256 before = rt.balanceOf(address(this));
        rt.safeTransferFrom(msg.sender, address(this), amount);
        received = rt.balanceOf(address(this)) - before;
    }

    function _notify(Pool storage p, uint256 i, uint256 received)
        internal
        returns (uint256 rate, uint64 finish)
    {
        if (received == 0) revert InvalidAmount();
        // Uncapped (buckets and snapshots) so a long-idle pool, or one crowded with dust locks expiring hour
        // after hour, never blocks Lodestar's distribute; the caller pays the catch-up gas.
        _updatePool(p, type(uint256).max, type(uint256).max, true);

        // The new end is weighted by amount: what is still dripping keeps its remaining time, while the
        // payout and anything that dripped with nobody locked get a full 3 days. Dust barely moves the
        // end, splitting a payout changes nothing, and the empty-pool carry can't be squeezed into the
        // last seconds of a drip.
        Stream storage st = p.streams[i];
        uint256 left = st.periodFinish > block.timestamp ? st.periodFinish - block.timestamp : 0;
        uint256 leftover = st.rewardRate * left;
        uint256 fresh = received * RATE_PREC + st.unallocated;
        uint256 total = leftover + fresh;
        uint256 duration = total == 0 ? DRIP : (leftover * left + fresh * DRIP) / total;
        if (duration == 0) duration = 1;
        st.rewardRate = total / duration;
        st.periodFinish = uint64(block.timestamp + duration);
        st.unallocated = 0;
        st.totalDistributed += received;
        return (st.rewardRate, st.periodFinish);
    }

    /// @dev Pays both streams. Returns the reward-token amount; the stake-token amount has its own event.
    function _claim(uint256 lockId, address to) internal returns (uint256 amount) {
        Lock storage l = _lock(lockId);
        if (msg.sender != l.owner) revert NotOwner();
        if (l.poolId == 0) return 0;
        Pool storage p = _pools[l.poolId];
        _settle(p, l);
        amount = _payReward(p, l, lockId, to);
        _payStake(p, l, lockId, to);
    }

    function _payReward(Pool storage p, Lock storage l, uint256 lockId, address to) internal returns (uint256 amount) {
        amount = l.rewardsAccrued;
        if (amount != 0) {
            l.rewardsAccrued = 0;
            address rt = p.rewardToken;
            if (rt == address(0)) {
                // state is written first and every entry point is nonReentrant
                (bool ok,) = to.call{value: amount}("");
                if (!ok) revert PayoutFailed();
            } else {
                IERC20(rt).safeTransfer(to, amount);
            }
            emit RewardsClaimed(lockId, to, amount);
        }
    }

    function _payStake(Pool storage p, Lock storage l, uint256 lockId, address to) internal returns (uint256 amount) {
        amount = l.stakeRewardsAccrued;
        if (amount != 0) {
            l.stakeRewardsAccrued = 0;
            IERC20(p.stakeToken).safeTransfer(to, amount);
            emit StakeRewardsClaimed(lockId, to, amount);
        }
    }

    function _settle(Pool storage p, Lock storage l) internal {
        _updatePool(p, MAX_BUCKETS_PER_CALL, MAX_EXPIRING_PER_CALL, true);
        bool ended = l.unlockAt <= p.cursor;
        Stream storage r = p.streams[REWARD];
        uint256 end = ended ? r.rppAtBucket[l.unlockAt] : r.rewardPerPoint;
        if (end > l.rewardPerPointPaid) {
            l.rewardsAccrued += _earned(l.points, end, l.rewardPerPointPaid);
            l.rewardPerPointPaid = end;
        }
        Stream storage k = p.streams[STAKE];
        end = ended ? k.rppAtBucket[l.unlockAt] : k.rewardPerPoint;
        if (end > l.stakeRewardPerPointPaid) {
            l.stakeRewardsAccrued += _earned(l.points, end, l.stakeRewardPerPointPaid);
            l.stakeRewardPerPointPaid = end;
        }
    }

    function _earned(uint256 points, uint256 rppEnd, uint256 rppPaid) internal pure returns (uint256) {
        if (rppEnd <= rppPaid) return 0;
        return Math.mulDiv(points, rppEnd - rppPaid, ACC_PREC * RATE_PREC);
    }

    /// @dev Walk every hour boundary since the last update, accruing rewards up to each boundary and then
    /// removing the points that expire there. Returns false if it stopped early at `maxBuckets`.
    function _updatePool(Pool storage p, uint256 maxBuckets, uint256 maxSnapshots, bool revertIfBehind)
        internal
        returns (bool)
    {
        uint64 b = p.cursor + BUCKET;
        uint256 n;
        uint256 snapshots;
        while (b <= block.timestamp) {
            uint256 expiring = p.pointsExpiring[b];
            if (n == maxBuckets || (expiring != 0 && snapshots == maxSnapshots)) {
                if (revertIfBehind) revert PoolNeedsPoke();
                return false;
            }
            _accrue(p, REWARD, p.lastUpdate, b);
            _accrue(p, STAKE, p.lastUpdate, b);
            p.lastUpdate = b;
            if (expiring != 0) {
                ++snapshots;
                p.streams[REWARD].rppAtBucket[b] = p.streams[REWARD].rewardPerPoint;
                // a pool that never got stake-token rewards reads 0 here anyway, so skip the write
                uint256 stakeRpp = p.streams[STAKE].rewardPerPoint;
                if (stakeRpp != 0) p.streams[STAKE].rppAtBucket[b] = stakeRpp;
                p.totalPoints -= expiring;
                delete p.pointsExpiring[b];
            }
            p.cursor = b;
            b += BUCKET;
            ++n;
        }
        _accrue(p, REWARD, p.lastUpdate, uint64(block.timestamp));
        _accrue(p, STAKE, p.lastUpdate, uint64(block.timestamp));
        p.lastUpdate = uint64(block.timestamp);
        return true;
    }

    function _accrue(Pool storage p, uint256 i, uint64 from, uint64 to) internal {
        Stream storage st = p.streams[i];
        uint256 amt = _dripped(st.rewardRate, st.periodFinish, from, to);
        if (amt == 0) return;
        if (p.totalPoints == 0) {
            st.unallocated += amt;
        } else {
            st.rewardPerPoint += Math.mulDiv(amt, ACC_PREC, p.totalPoints);
        }
    }

    function _dripped(uint256 rate, uint64 periodFinish, uint64 from, uint64 to) internal pure returns (uint256) {
        uint64 a = from < periodFinish ? from : periodFinish;
        uint64 z = to < periodFinish ? to : periodFinish;
        return z > a ? rate * (z - a) : 0;
    }

    function _pendingFor(Pool storage p, uint256 i, Lock storage l, uint256 paid) internal view returns (uint256) {
        (uint256 rppNow, uint256 rppAtUnlock, bool unlockReached) = _simulate(p, i, l.unlockAt);
        return _earned(l.points, unlockReached ? rppAtUnlock : rppNow, paid);
    }

    function _ratePerSecond(uint256 lockId, uint256 i) internal view returns (uint256) {
        Lock storage l = _lock(lockId);
        if (l.poolId == 0 || l.withdrawn || block.timestamp >= l.unlockAt) return 0;
        Pool storage p = _pools[l.poolId];
        Stream storage st = p.streams[i];
        if (block.timestamp >= st.periodFinish) return 0;
        (,,, uint256 totalPoints,) = _simulateFull(p, i, 0);
        if (totalPoints == 0) return 0;
        return Math.mulDiv(l.points, st.rewardRate, totalPoints);
    }

    /// @dev Read-only replay of `_updatePool` for stream `i`. Also reports the reward-per-point at
    /// `unlockAt` if that boundary is passed during the replay or was already processed.
    function _simulate(Pool storage p, uint256 i, uint64 unlockAt)
        internal
        view
        returns (uint256 rppNow, uint256 rppAtUnlock, bool unlockReached)
    {
        if (unlockAt <= p.cursor) {
            (rppNow,,,,) = _simulateFull(p, i, 0);
            return (rppNow, p.streams[i].rppAtBucket[unlockAt], true);
        }
        (rppNow, rppAtUnlock, unlockReached,,) = _simulateFull(p, i, unlockAt);
    }

    function _simulateFull(Pool storage p, uint256 i, uint64 watch)
        internal
        view
        returns (uint256 rpp, uint256 rppAtWatch, bool watchReached, uint256 totalPoints, uint256 carry)
    {
        Stream storage st = p.streams[i];
        rpp = st.rewardPerPoint;
        totalPoints = p.totalPoints;
        carry = st.unallocated;
        uint64 last = p.lastUpdate;
        uint64 b = p.cursor + BUCKET;
        while (b <= block.timestamp) {
            uint256 amt = _dripped(st.rewardRate, st.periodFinish, last, b);
            if (amt != 0) {
                if (totalPoints != 0) rpp += Math.mulDiv(amt, ACC_PREC, totalPoints);
                else carry += amt;
            }
            last = b;
            if (b == watch) {
                rppAtWatch = rpp;
                watchReached = true;
            }
            totalPoints -= p.pointsExpiring[b];
            b += BUCKET;
        }
        uint256 tail = _dripped(st.rewardRate, st.periodFinish, last, uint64(block.timestamp));
        if (tail != 0) {
            if (totalPoints != 0) rpp += Math.mulDiv(tail, ACC_PREC, totalPoints);
            else carry += tail;
        }
    }

    function _tierMultiplier(Tier[] storage tiers, uint256 duration) internal view returns (uint16) {
        for (uint256 i = tiers.length; i > 0; --i) {
            if (tiers[i - 1].minDuration <= duration) return tiers[i - 1].multiplierBps;
        }
        return 0;
    }

    function _validateTiers(Tier[] calldata tiers) internal pure {
        if (tiers.length == 0 || tiers.length > MAX_TIERS) revert InvalidTiers();
        for (uint256 i; i < tiers.length; ++i) {
            if (tiers[i].multiplierBps == 0 || tiers[i].multiplierBps > MAX_MULTIPLIER_BPS) {
                revert InvalidTiers();
            }
            if (tiers[i].minDuration < BUCKET) revert InvalidTiers();
            // longer locks never earn a lower multiplier than shorter ones
            if (
                i > 0
                    && (tiers[i].minDuration <= tiers[i - 1].minDuration
                        || tiers[i].multiplierBps < tiers[i - 1].multiplierBps)
            ) revert InvalidTiers();
        }
    }

    function _pool(uint256 poolId) internal view returns (Pool storage p) {
        if (poolId == 0 || poolId > poolCount) revert UnknownPool();
        p = _pools[poolId];
    }

    function _lock(uint256 lockId) internal view returns (Lock storage l) {
        if (lockId == 0 || lockId > lockCount) revert UnknownLock();
        l = _locks[lockId];
    }

    function _floorBucket(uint256 t) internal pure returns (uint64) {
        return uint64(t - (t % BUCKET));
    }

    /// @dev Reverts instead of wrapping: an unlock time near uint64 max must not round into the past.
    function _ceilBucket(uint256 t) internal pure returns (uint64) {
        uint256 r = t % BUCKET;
        uint256 c = r == 0 ? t : t + BUCKET - r;
        if (c > type(uint64).max) revert InvalidUnlock();
        return uint64(c);
    }
}
