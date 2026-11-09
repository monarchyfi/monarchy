// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IListingDesk} from "./interfaces/IListingDesk.sol";
import {IBuybackSwapper, INativeBuybackSwapper} from "./interfaces/IBuybackSwapper.sol";
import {IFeeSource} from "./interfaces/IFeeSource.sol";
import {IExile} from "./interfaces/IExile.sol";
import {ISandfall} from "./interfaces/ISandfall.sol";
import {ILodestar} from "./interfaces/ILodestar.sol";
import {ILodestarFactory} from "./interfaces/ILodestarFactory.sol";

/// @title Lodestar
/// @notice Fee router for one launchpad token (Ascend, Volta, ElysPump, Boxa, Kleos or Montra). Once it holds the
/// token's creator role on the launchpad, every creator fee lands here, and anyone can call `distribute()` to
/// route it:
///   - project-token fees are burned, or, if the creator chose so, paid in full to Exile lockers;
///   - quote fees (an ERC-20, or native HYPE) are split by the creator's chosen percentages between buyback
///     and burn, Exile holder rewards and the Team Treasury (a Sandfall stream).
/// Everything launchpad specific goes through the launchpad's fee-source adapter, fixed at initialize, and the
/// router only ever sends launchpad calls to the contract that holds the creator role (and, on Volta, to the
/// escrow that pays it).
/// Split changes wait behind a 12 hour timelock. The creator role can be locked here forever, so the
/// router can't be swapped out; even then it can move to this token's router on a newer Monarchy
/// factory, proposed by the steward and announced 7 days ahead. No protocol fee. Deployed as one minimal
/// clone per token by LodestarFactory.
contract Lodestar is ILodestar, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @dev A buy that costs more than this in fees and tax right now (a launch's anti-snipe window, a raised tax)
    /// is not tried; the buyback share waits in reserve.
    /// Ascend v5 pools charge a fixed 1% to 10% plus up to 1% to a builder, so this allows up to 11%: the minimum
    /// output already allows for the fee, and a higher fee only makes a sandwich of the small capped buys cost more.
    /// It applies to every launchpad: a buy fee or tax of up to 11% elsewhere is bought through too.
    uint256 public constant MAX_SWAP_COST_BPS = 1_100;
    uint256 public constant MIN_SLIPPAGE_BPS = 100;
    uint256 public constant MAX_SLIPPAGE_BPS = 2_000;
    uint64 public constant TIMELOCK = 12 hours;
    /// @dev A ready config change must be executed within this window, or proposed again.
    uint64 public constant EXECUTION_WINDOW = 7 days;
    /// @dev After a skipped buyback that a smaller one could have fixed, the next attempt halves, down to 1/256
    /// of the amount due.
    uint8 public constant MAX_BUYBACK_SHIFT = 8;
    /// @dev Each buyback spends at most this share of the quote side of the pool's active liquidity
    /// (valued at the EMA price, or at spot when that gives a smaller depth). A buy that small moves
    /// the price about 1%, which is less than the 1% fee a sandwich pays each way, so sandwiching it
    /// doesn't pay.
    uint256 public constant MAX_BUY_DEPTH_BPS = 50;
    /// @dev At most one buyback every 30 minutes. The depth cap bounds one buy; without a gap between buys a
    /// caller could push several capped pieces through in one transaction, between their own buy and
    /// sell, and collect about 1% per piece for one 2% round trip in fees. The keeper runs every 3 hours,
    /// so the gap costs nothing in the normal flow.
    uint64 public constant BUYBACK_INTERVAL = 30 minutes;
    /// @notice How long a proposed move to a newer Lodestar waits before anyone can execute it.
    uint64 public constant UPGRADE_DELAY = 7 days;
    /// @dev How many hours of Exile's reward pool one distribute catches up before paying holders (Exile's
    /// own per-call cap, with at most 300 hours in which locks expire). A pool further behind, after a long
    /// outage or with dust locks expiring hour after hour, parks the holder payouts for that call instead of
    /// running distribute out of gas; each call still moves the pool forward by this much, and a call sent
    /// with too little gas for that reverts (`CatchUpOutOfGas`) instead of parking without moving it.
    uint256 public constant EXILE_CATCH_UP = 720;
    address public factory;
    /// @notice The launchpad's fee-source adapter: views and the calls this router sends as the creator.
    IFeeSource public source;
    /// @notice The contract that holds the creator role (Ascend's testnet launchpad, an Ascend v5 pool's escrow,
    /// Volta's creator NFT, an ElysPump, Boxa, Kleos or Montra hook). With `payer`, the only address this router
    /// sends launchpad calls to.
    address public hook;
    /// @notice The contract that pays the role's fees when it isn't `hook` (Volta's fee escrow), else address(0).
    /// Read from the adapter once, at initialize, like `hook`.
    address public payer;
    IListingDesk public desk;
    IExile public exile;
    ISandfall public sandfall;
    bytes32 public poolId;
    IERC20 public token;
    /// @notice The quote asset, address(0) for native HYPE.
    IERC20 public quote;
    bool public tokenIs0;
    /// @notice Where buybacks and token-side burns go: the address the token itself counts as burned.
    address public burnSink;
    uint256 public exilePoolId;
    uint256 public treasuryStreamId;

    address public steward;
    Config internal _cfg;
    Config internal _pendingCfg;
    uint64 public pendingEta;
    uint64 public creatorLockedUntil;
    uint256 public buybackReserve;
    bool internal _initialized;

    uint256 public totalTokenBurned; // token-side fees burned directly
    uint256 public totalTokenToHolders; // token-side fees paid to Exile lockers
    uint256 public totalBuybackQuote;
    uint256 public totalBuybackTokensBurned;
    uint256 public totalHoldersQuote;
    uint256 public totalTreasuryQuote;
    uint64 public lastDistributeAt;
    /// @notice Each attempt buys `due >> buybackShift`. Rises by one after a skipped buyback and falls by
    /// one after a successful one, so a reserve too big for the pool is bought back in smaller pieces.
    uint8 public buybackShift;
    /// @notice When the last buyback went through; the next one waits `BUYBACK_INTERVAL`.
    uint64 public lastBuybackAt;
    /// @notice When the attempt size was last halved. It halves at most once per `BUYBACK_INTERVAL`, the
    /// same rate at which successes double it back, so a burst of failed calls can't shrink it for hours.
    uint64 public lastHalvingAt;
    /// @notice Holder rewards or treasury top-ups that couldn't be paid out yet; retried on the next distribute.
    uint256 public holdersReserve;
    uint256 public treasuryReserve;
    /// @notice A proposed move of the creator role to this token's router on the factory's successor.
    address public upgradeFactory;
    address public upgradeTarget;
    uint64 public upgradeEta;

    event Initialized(bytes32 indexed poolId, address indexed token, address quote, address steward, Config config);
    event Distributed(
        uint256 tokenBurned,
        uint256 tokenToHolders,
        uint256 quoteRouted,
        uint256 buybackQuote,
        uint256 buybackTokensBurned,
        uint256 holdersQuote,
        uint256 treasuryQuote
    );
    event BuybackSkipped(uint256 amount, uint256 minOut);
    event TokenBurnFailed(uint256 amount);
    event TokenHoldersPayoutFailed(uint256 amount);
    event CollectFailed();
    event ClaimFailed();
    event HoldersPayoutFailed(uint256 amount);
    event TreasuryPayoutFailed(uint256 amount);
    event ConfigProposed(Config config, uint64 eta);
    event ConfigExecuted(Config config);
    event ConfigCancelled();
    event CreatorRoleLocked(uint64 until);
    event CreatorAccepted();
    event CreatorTransferOutStarted(address next);
    event ForeignRoleReleased(address indexed foreignToken, address to);
    event ListingEnrolled(uint256 cap);
    event ListingClosed();
    event StewardTransferred(address indexed previous, address indexed next);
    event UpgradeProposed(address indexed factory, address indexed target, uint64 eta);
    event UpgradeCancelled();
    event UpgradeExecuted(address indexed target);

    error AlreadyInitialized();
    error OnlySteward();
    error InvalidConfig();
    error NoPendingConfig();
    error TimelockActive();
    error CreatorNotPending();
    error CreatorRoleIsLocked();
    error NotExtending();
    error ZeroAddress();
    error ProposalExpired();
    error OnlySelf();
    error BuybackShort();
    error CreatorTransferPending();
    error SelfTransfer();
    error NoSuccessor();
    error NoPendingUpgrade();
    error SuccessorChanged();
    error CatchUpOutOfGas();
    error BadCallTarget();
    error NativeNotAccepted();
    error OnlyFactory();

    struct Market {
        uint256 ema; // sqrt prices, Q64.96
        uint256 spot;
        uint256 liq;
        uint256 cost; // bps a buy pays in fees and tax
    }

    constructor() {
        _initialized = true; // the implementation itself can never be initialized
    }

    modifier onlySteward() {
        if (msg.sender != steward) revert OnlySteward();
        _;
    }

    modifier onlyStewardOrFactory() {
        if (msg.sender != steward && msg.sender != factory) revert OnlySteward();
        _;
    }

    // ================================================================ setup (factory)

    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _validate(p.config);
        if (p.steward == address(0)) revert ZeroAddress();
        factory = msg.sender;
        source = IFeeSource(p.source);
        hook = p.hook;
        payer = p.payer;
        desk = IListingDesk(p.desk);
        exile = IExile(p.exile);
        sandfall = ISandfall(p.sandfall);
        poolId = p.poolId;
        token = IERC20(p.token);
        quote = IERC20(p.quote);
        tokenIs0 = p.tokenIs0;
        burnSink = p.burnSink;
        exilePoolId = p.exilePoolId;
        treasuryStreamId = p.treasuryStreamId;
        steward = p.steward;
        _cfg = p.config;
        emit Initialized(p.poolId, p.token, p.quote, p.steward, p.config);
    }

    /// @notice Second half of a two-step creator handover (Ascend, Boxa). On Ascend v5 it works only once the
    /// launchpad's 48 hour wait has passed, so it is called then, by anyone. The current creator must have proposed
    /// this Lodestar on the launchpad first; that call is the consent, so anyone may finish the hand-off. The
    /// factory calls this at deploy, and it works again later if the role ever left (an expired lock, a hand-out
    /// the steward reverses), so a token can come back to Monarchy. On one-step launchpads (Volta, ElysPump, Kleos,
    /// Montra) the role simply arrives and there is nothing to accept.
    /// A creator handing the role back should claim their own fees first: on Ascend whatever is still owed when
    /// the hand-off completes is paid to the new creator, this router, and routed. Accepting also clears the
    /// listing election on Ascend, so the steward enrols again afterwards if wanted.
    function acceptCreator() external {
        if (source.pendingCreator(address(token), poolId) != address(this)) revert CreatorNotPending();
        _run(source.acceptCalls(address(token), poolId, address(this)), true);
        emit CreatorAccepted();
    }

    /// @notice Fees on Volta, ElysPump, Boxa, Kleos and Montra arrive in native HYPE. Plain accept, no logic, so a payout landing in
    /// the middle of `distribute` can't re-enter anything. Routers quoted in an ERC-20 refuse HYPE, which they
    /// could never route.
    receive() external payable {
        if (address(quote) != address(0)) revert NativeNotAccepted();
    }

    // ================================================================ routing (anyone)

    /// @notice Collect and claim this token's creator fees from the launchpad and route everything this
    /// router holds. Permissionless. The buyback's minimum output comes from an EMA price (or spot,
    /// whichever asks for more), each buy is capped at a small share of the pool's depth, and buys are at
    /// least 30 minutes apart, so sandwiching them doesn't pay. Any step that fails keeps its amount here
    /// and retries next time; the other steps still run.
    function distribute() external nonReentrant {
        address t_ = address(token);
        try source.poke(t_, poolId) {} catch {}
        // low-level calls, so even a changed return shape can't block routing
        bool ok;
        try source.collectCalls(t_, poolId, address(this)) returns (IFeeSource.Call[] memory cs) {
            ok = _run(cs, false);
        } catch {}
        if (!ok) emit CollectFailed(); // Ascend's keeper may have collected already
        ok = false;
        try source.claimCalls(t_, poolId, address(this)) returns (IFeeSource.Call[] memory cs) {
            ok = _run(cs, false);
        } catch {}
        if (!ok) emit ClaimFailed();

        Config memory c = _cfg;
        // catch Exile's pool up in one bounded call first, so the payouts below have no hours left to walk
        bool exileCurrent = _catchUpExile();

        // project-token side: all of it is burned, or all of it goes to Exile lockers. Balance based, so a
        // payout that failed last time is simply part of the next one (under whatever the config says then).
        uint256 t = token.balanceOf(address(this));
        uint256 tBurned;
        uint256 tHolders;
        if (t > 0) {
            if (c.tokenToHolders) {
                if (exileCurrent) {
                    token.forceApprove(address(exile), t);
                    try exile.notifyStakeReward(exilePoolId, t) {
                        tHolders = t;
                        totalTokenToHolders += t;
                    } catch {
                        token.forceApprove(address(exile), 0);
                    }
                }
                if (tHolders == 0) emit TokenHoldersPayoutFailed(t);
            } else if (_tryTransfer(token, burnSink, t)) {
                tBurned = t;
                totalTokenBurned += t;
            } else {
                emit TokenBurnFailed(t);
            }
        }

        // quote side: balance based, so fees claimed by anyone else and listing refunds are routed too
        uint256 q = _quoteBalance() - buybackReserve - holdersReserve - treasuryReserve;
        uint256 burnQ = q * c.burnBps / BPS;
        uint256 holdQ = q * c.holdersBps / BPS;
        uint256 rest = q - burnQ - holdQ;
        // the rounding remainder goes to a share that is switched on
        if (c.treasuryBps == 0) {
            if (c.holdersBps > 0) holdQ += rest;
            else burnQ += rest;
            rest = 0;
        }
        uint256 treasQ = rest + treasuryReserve;
        holdQ += holdersReserve;

        (uint256 spent, uint256 bought) = _buyback(c, burnQ + buybackReserve);

        bool native = address(quote) == address(0);
        if (holdQ > 0) {
            bool paid;
            if (exileCurrent) {
                if (!native) quote.forceApprove(address(exile), holdQ);
                try exile.notifyReward{value: native ? holdQ : 0}(exilePoolId, holdQ) {
                    paid = true;
                } catch {
                    if (!native) quote.forceApprove(address(exile), 0);
                }
            }
            if (paid) {
                totalHoldersQuote += holdQ;
                holdersReserve = 0;
            } else {
                holdersReserve = holdQ;
                emit HoldersPayoutFailed(holdQ);
                holdQ = 0;
            }
        }
        if (treasQ > 0) {
            bool paid;
            if (treasQ <= type(uint128).max) {
                if (!native) quote.forceApprove(address(sandfall), treasQ);
                try sandfall.topUp{value: native ? treasQ : 0}(treasuryStreamId, uint128(treasQ)) {
                    paid = true;
                } catch {
                    if (!native) quote.forceApprove(address(sandfall), 0);
                }
            }
            if (paid) {
                totalTreasuryQuote += treasQ;
                treasuryReserve = 0;
            } else {
                treasuryReserve = treasQ;
                emit TreasuryPayoutFailed(treasQ);
                treasQ = 0;
            }
        }

        lastDistributeAt = uint64(block.timestamp);
        emit Distributed(tBurned, tHolders, q, spent, bought, holdQ, treasQ);
    }

    function _buyback(Config memory c, uint256 buyAmt) internal returns (uint256 spent, uint256 bought) {
        if (buyAmt > 0 && c.swapper != address(0) && block.timestamp >= lastBuybackAt + BUYBACK_INTERVAL) {
            Market memory m = _market();
            uint256 cap = _maxBuyback(m.ema, m.spot, m.liq);
            if (cap == 0 || m.cost > MAX_SWAP_COST_BPS) {
                // no EMA, no active liquidity to size the buy against (a pool below Ascend's first band), or a
                // buy tax too high right now: nothing is tried, so the reserve waits and nothing counts towards
                // halving
                emit BuybackSkipped(0, 0);
            } else {
                uint256 full = buyAmt > cap ? cap : buyAmt;
                uint256 attempt = full >> buybackShift;
                if (attempt == 0) attempt = full;
                uint256 minOut = _minOut(m.ema, m.spot, attempt, c.maxSlippageBps, m.cost);
                bool ok;
                if (minOut > 0) {
                    try this.buybackStep(c.swapper, attempt, minOut) returns (uint256 s_, uint256 b_) {
                        (spent, bought, ok) = (s_, b_, true);
                    } catch {}
                }
                if (ok) {
                    lastBuybackAt = uint64(block.timestamp);
                    totalBuybackQuote += spent;
                    totalBuybackTokensBurned += bought;
                    if (buybackShift > 0) --buybackShift;
                } else {
                    // only a miss that a smaller attempt could fix halves the next one. Dust attempts are
                    // exempt, and so is an EMA still trailing a pump: when its floor asks for more than a
                    // swap at spot pays even with no price impact, no size gets through, so waiting for
                    // trades to move the EMA can't shrink the next real buyback. It halves at most once per
                    // interval, so repeated calls during one pump can't run it to 1/256.
                    if (
                        buybackShift < MAX_BUYBACK_SHIFT && attempt * 256 >= cap
                            && block.timestamp >= lastHalvingAt + BUYBACK_INTERVAL
                            && _floor(m.ema, attempt, c.maxSlippageBps, m.cost)
                                < _floor(m.spot, attempt, 0, m.cost)
                    ) {
                        ++buybackShift;
                        lastHalvingAt = uint64(block.timestamp);
                    }
                    emit BuybackSkipped(attempt, minOut);
                }
            }
        }
        buybackReserve = buyAmt - spent;
    }

    /// @notice One buyback, checked by what actually happened: at most `amountIn` quote left this router
    /// and at least `minOut` tokens reached the burn address. Only callable by this router, from
    /// `distribute`, so a bad swap reverts here and the quote stays in reserve.
    function buybackStep(address swapper, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 spent, uint256 burned)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        address sink = burnSink;
        uint256 quoteBefore = _quoteBalance();
        uint256 deadBefore = token.balanceOf(sink);
        if (address(quote) == address(0)) {
            INativeBuybackSwapper(swapper).buyExactIn{value: amountIn}(poolId, amountIn, minOut, sink);
        } else {
            quote.forceApprove(swapper, amountIn);
            IBuybackSwapper(swapper).buyExactIn(poolId, amountIn, minOut, sink);
            quote.forceApprove(swapper, 0);
        }
        spent = quoteBefore - _quoteBalance();
        burned = token.balanceOf(sink) - deadBefore;
        if (burned < minOut || spent > amountIn) revert BuybackShort();
    }

    /// @notice Minimum tokens to accept when buying with `quoteIn`: the stricter of the floors at the EMA
    /// price and at the pool's spot price, minus the pool's fee or tax and the slippage allowance. Returns 0
    /// (no buyback) when there is no EMA: spot alone is never trusted, since a sandwich can move it in
    /// the same transaction. Spot can only tighten the floor, so a dump (which leaves the EMA stale and
    /// high) can't loosen it either.
    function quoteMinOut(uint256 quoteIn, uint256 slippageBps) public view returns (uint256) {
        Market memory m = _market();
        return _minOut(m.ema, m.spot, quoteIn, slippageBps, m.cost);
    }

    /// @notice Largest single buyback right now. 0 means none can go through now: there is no EMA, or the pool
    /// has no active liquidity to size it against (or doesn't report it).
    function maxBuyback() external view returns (uint256) {
        Market memory m = _market();
        return _maxBuyback(m.ema, m.spot, m.liq);
    }

    /// @notice Earliest time the next buyback can go through (0 = nothing bought yet, no wait).
    function nextBuybackAt() external view returns (uint64) {
        return lastBuybackAt == 0 ? 0 : lastBuybackAt + BUYBACK_INTERVAL;
    }

    /// @dev The EMA and spot sqrt prices, the active liquidity and the swap cost, all from the adapter. A read
    /// that fails leaves zeros, which `_buyback` treats as "wait"; a cost it can't read counts as too high.
    function _market() internal view returns (Market memory m) {
        try source.prices(address(token), poolId) returns (uint160 s, uint160 e, uint128 l_) {
            (m.spot, m.ema, m.liq) = (s, e, l_);
        } catch {}
        m.cost = type(uint256).max;
        try source.swapCostBps(address(token), poolId) returns (uint256 c_) {
            m.cost = c_;
        } catch {}
    }

    /// @dev Quote side of the active liquidity: L * sqrtP for currency1, L / sqrtP for currency0. Valued
    /// at whichever of the EMA and spot prices gives the smaller depth: a pump raises spot and the EMA
    /// stays in charge, a dump lowers spot and the cap shrinks with it instead of trusting a stale EMA.
    /// 0 when there is nothing to size against, which `_buyback` treats as "wait", never as "no cap".
    function _maxBuyback(uint256 ema, uint256 spot, uint256 liq) internal view returns (uint256) {
        if (ema == 0 || liq == 0) return 0;
        uint256 sp = ema;
        if (spot != 0) sp = tokenIs0 ? Math.min(ema, spot) : Math.max(ema, spot);
        uint256 depth = tokenIs0 ? Math.mulDiv(liq, sp, 1 << 96) : Math.mulDiv(liq, 1 << 96, sp);
        uint256 cap = depth * MAX_BUY_DEPTH_BPS / BPS;
        return cap == 0 ? 1 : cap;
    }

    function _minOut(uint256 ema, uint256 spot, uint256 quoteIn, uint256 slippageBps, uint256 cost)
        internal
        view
        returns (uint256)
    {
        if (ema == 0 || cost + slippageBps >= BPS) return 0;
        return Math.max(_floor(ema, quoteIn, slippageBps, cost), _floor(spot, quoteIn, slippageBps, cost));
    }

    /// @dev Tokens `quoteIn` buys at sqrt price `sp`, less the swap's fee or tax (`cost`) and the slippage allowance.
    function _floor(uint256 sp, uint256 quoteIn, uint256 slippageBps, uint256 cost)
        internal
        view
        returns (uint256)
    {
        if (sp == 0 || cost + slippageBps >= BPS) return 0;
        // price = (sp / 2^96)^2 = currency1 per currency0
        uint256 expected = tokenIs0
            ? Math.mulDiv(Math.mulDiv(quoteIn, 1 << 96, sp), 1 << 96, sp)
            : Math.mulDiv(Math.mulDiv(quoteIn, sp, 1 << 96), sp, 1 << 96);
        return expected * (BPS - cost - slippageBps) / BPS;
    }

    function executeConfig() external {
        if (pendingEta == 0) revert NoPendingConfig();
        if (block.timestamp < pendingEta) revert TimelockActive();
        if (block.timestamp > pendingEta + EXECUTION_WINDOW) revert ProposalExpired();
        _cfg = _pendingCfg;
        delete _pendingCfg;
        pendingEta = 0;
        emit ConfigExecuted(_cfg);
    }

    // ================================================================ steward

    function proposeConfig(Config calldata c) external onlySteward {
        _validate(c);
        _pendingCfg = c;
        pendingEta = uint64(block.timestamp) + TIMELOCK;
        emit ConfigProposed(c, pendingEta);
    }

    function cancelConfig() external onlySteward {
        if (pendingEta == 0) revert NoPendingConfig();
        delete _pendingCfg;
        pendingEta = 0;
        emit ConfigCancelled();
    }

    /// @notice Promise the creator role stays with this router until `until` (type(uint64).max = forever).
    /// Can only be extended, and not while a hand-off away from this router is pending (it could be accepted after
    /// locking). A hand-off to this router still waiting to be accepted (Ascend v5's 48 hours) is fine: the lock
    /// binds from the moment the router holds the role, and until then the creator can still cancel, so read
    /// `creatorRoleLocked()` rather than this value alone.
    function lockCreatorRole(uint64 until) external onlyStewardOrFactory {
        if (until <= creatorLockedUntil || until <= block.timestamp) revert NotExtending();
        address pending = source.pendingCreator(address(token), poolId);
        if (pending != address(0) && pending != address(this)) revert CreatorTransferPending();
        creatorLockedUntil = until;
        emit CreatorRoleLocked(until);
    }

    /// @notice Hand the creator role to `next`: proposed on two-step launchpads (Ascend, Boxa), where `next`
    /// accepts, and moved at once on one-step launchpads (Volta, ElysPump, Kleos, Montra). Blocked while locked;
    /// `next = 0` cancels a pending hand-off and is always allowed.
    function transferCreatorOut(address next) external onlySteward {
        if (next != address(0) && block.timestamp < creatorLockedUntil) revert CreatorRoleIsLocked();
        // a hand-off to itself would let anyone "accept" and clear the listing election for nothing
        if (next == address(this)) revert SelfTransfer();
        _run(source.transferOutCalls(address(token), poolId, next), true);
        emit CreatorTransferOutStarted(next);
    }

    /// @notice Pass on another coin's creator role that landed here by mistake: one-step launchpads move a role
    /// in one call to any address, so a creator can send it to the wrong router. Only the
    /// factory calls this, from `rescueDeploy`, which hands the role to that coin's own router in the same
    /// transaction. This router's own role, settings and funds are untouched.
    function releaseForeignRole(address foreignToken, address to) external nonReentrant {
        if (msg.sender != factory) revert OnlyFactory();
        if (foreignToken == address(token)) revert SelfTransfer();
        (bytes32 foreignPoolId, address foreignHook,) = source.resolve(foreignToken, address(quote));
        _runOn(foreignHook, address(0), source.transferOutCalls(foreignToken, foreignPoolId, to), true);
        emit ForeignRoleReleased(foreignToken, to);
    }

    /// @notice The one way out of the creator lock: propose moving the role to this token's router on the
    /// newer factory that this router's factory names as its successor. Anyone can execute the move 7 days
    /// later, within the 7 days after that, so holders see it coming. It needs both the factory owner (who
    /// names the successor) and the steward (who proposes), and a different successor named meanwhile stops
    /// it. Proposing again replaces a pending move and restarts the wait.
    function proposeUpgrade() external onlySteward {
        address next = ILodestarFactory(factory).successor();
        if (next == address(0)) revert NoSuccessor();
        (address target,) = ILodestarFactory(next).predict(address(token), address(quote));
        if (target == address(0) || target == address(this)) revert NoSuccessor();
        upgradeFactory = next;
        upgradeTarget = target;
        upgradeEta = uint64(block.timestamp) + UPGRADE_DELAY;
        emit UpgradeProposed(next, target, upgradeEta);
    }

    function cancelUpgrade() external onlySteward {
        if (upgradeEta == 0) revert NoPendingUpgrade();
        _clearUpgrade();
        emit UpgradeCancelled();
    }

    /// @notice Hand the creator role to the proposed router, lock or no lock. On two-step launchpads the new
    /// router completes it on its side, and until it does the steward can still cancel with
    /// `transferCreatorOut(0)`, so the role stays here. On one-step launchpads the role moves at once, so the new
    /// router must already be deployed (the steward deploys it on the successor factory during the notice).
    function executeUpgrade() external {
        if (upgradeEta == 0) revert NoPendingUpgrade();
        if (block.timestamp < upgradeEta) revert TimelockActive();
        if (block.timestamp > upgradeEta + EXECUTION_WINDOW) revert ProposalExpired();
        if (ILodestarFactory(factory).successor() != upgradeFactory) revert SuccessorChanged();
        address target = upgradeTarget;
        if (source.handover() == IFeeSource.Handover.OneStep && target.code.length == 0) {
            revert NoSuccessor();
        }
        _clearUpgrade();
        _run(source.transferOutCalls(address(token), poolId, target), true);
        emit UpgradeExecuted(target);
    }

    /// @notice Enrol in Ascend's listing set-aside: 20% of the creator's quote fees are held toward a
    /// HyperCore listing until `cap` is reached.
    function enrollListing(uint256 cap) external onlyStewardOrFactory {
        desk.enroll(address(token), address(quote), cap);
        emit ListingEnrolled(cap);
    }

    function closeListing() external onlySteward {
        desk.close(poolId);
        emit ListingClosed();
    }

    function transferSteward(address next) external onlySteward {
        if (next == address(0)) revert ZeroAddress();
        emit StewardTransferred(steward, next);
        steward = next;
    }

    /// @notice Queue a new tier table for this token's Exile pool. This router is the pool's admin, so
    /// tier changes follow the steward (and move with `transferSteward`) and wait out Exile's 12 hour
    /// timelock; anyone can execute them on Exile once ready.
    function proposeTiers(IExile.Tier[] calldata tiers) external onlySteward {
        exile.proposeTiers(exilePoolId, tiers);
    }

    function cancelTiers() external onlySteward {
        exile.cancelTiers(exilePoolId);
    }

    // ================================================================ views

    function config() external view returns (Config memory) {
        return _cfg;
    }

    function pendingConfig() external view returns (Config memory cfg, uint64 eta) {
        return (_pendingCfg, pendingEta);
    }

    /// @notice What a distribute would route from fees already claimable on the launchpad plus this router's
    /// balance. Fees still sitting in the pool (not yet collected) are not included. `tokenSide` is burned, or
    /// paid to Exile lockers when `config().tokenToHolders` is set.
    function previewDistribute()
        external
        view
        returns (uint256 tokenSide, uint256 quoteTotal, uint256 burnQ, uint256 holdQ, uint256 treasQ)
    {
        (uint256 owedT, uint256 owedQ) = source.owed(address(token), poolId, address(this));
        tokenSide = token.balanceOf(address(this)) + owedT;
        quoteTotal = _quoteBalance() - buybackReserve - holdersReserve - treasuryReserve + owedQ;
        burnQ = quoteTotal * _cfg.burnBps / BPS;
        holdQ = quoteTotal * _cfg.holdersBps / BPS;
        treasQ = quoteTotal - burnQ - holdQ;
    }

    function isCreator() external view returns (bool) {
        return source.creator(address(token), poolId) == address(this);
    }

    /// @notice True while the creator lock actually binds: this router holds the role and the lock hasn't run out.
    /// `creatorLockedUntil` alone can be set before the role arrives (Ascend v5's 48 hour wait), when the creator
    /// can still cancel the hand-off. A launchpad's own override (an approved Ascend v5 community takeover) can
    /// still move the role; see the adapter's `takeoverRegistry`.
    function creatorRoleLocked() external view returns (bool) {
        return block.timestamp < creatorLockedUntil && source.creator(address(token), poolId) == address(this);
    }

    // ================================================================ internals

    function _validate(Config memory c) internal pure {
        if (uint256(c.burnBps) + c.holdersBps + c.treasuryBps != BPS) revert InvalidConfig();
        if (c.maxSlippageBps < MIN_SLIPPAGE_BPS || c.maxSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidConfig();
        }
    }

    function _clearUpgrade() internal {
        upgradeFactory = address(0);
        upgradeTarget = address(0);
        upgradeEta = 0;
    }

    /// @dev True when Exile's pool reached the present within `EXILE_CATCH_UP` hours. Exile's payouts catch up
    /// without a cap, so without this a pool weeks behind could make distribute need more gas than a block
    /// holds and revert, treasury and buyback included. A failed poke counts as not caught up.
    function _catchUpExile() internal returns (bool current) {
        uint256 g = gasleft();
        try exile.poke(exilePoolId, EXILE_CATCH_UP) returns (bool caughtUp) {
            current = caughtUp;
        } catch {
            // Out of gas inside the poke leaves this call the 1/64 EIP-150 holds back, which is enough to
            // finish with both payouts parked and the pool not moved at all, and a wallet's gas estimate
            // lands right there. Fail instead, so the caller sends enough. A poke that fails for any other
            // reason uses little gas and still only parks the payouts.
            if (gasleft() <= g / 63) revert CatchUpOutOfGas();
        }
    }

    /// @dev Send an adapter's call plan as this router. Only to `hook` or `payer`, never with value. `strict`
    /// bubbles the first failure (steward and factory actions); otherwise a failure stops the plan and returns
    /// false, so `distribute` keeps routing.
    function _run(IFeeSource.Call[] memory cs, bool strict) internal returns (bool) {
        return _runOn(hook, payer, cs, strict);
    }

    /// @dev Sends the adapter's calls, each of which must target `target` (the router's own hook, except when
    /// passing on another coin's role, where it is that coin's hook) or `alt` (the router's payer; 0 = none).
    function _runOn(address target, address alt, IFeeSource.Call[] memory cs, bool strict)
        internal
        returns (bool)
    {
        for (uint256 i; i < cs.length; ++i) {
            address to = cs[i].target;
            if (to != target && (alt == address(0) || to != alt)) {
                if (strict) revert BadCallTarget();
                return false;
            }
            (bool ok, bytes memory ret) = to.call(cs[i].data);
            if (!ok) {
                if (strict) {
                    assembly ("memory-safe") {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                return false;
            }
        }
        return true;
    }

    function _quoteBalance() internal view returns (uint256) {
        return address(quote) == address(0) ? address(this).balance : quote.balanceOf(address(this));
    }

    function _tryTransfer(IERC20 asset, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = address(asset).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
