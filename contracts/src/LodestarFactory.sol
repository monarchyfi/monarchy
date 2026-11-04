// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IFeeSource} from "./interfaces/IFeeSource.sol";
import {IExile} from "./interfaces/IExile.sol";
import {ISandfall} from "./interfaces/ISandfall.sol";
import {ILodestar} from "./interfaces/ILodestar.sol";

/// @title LodestarFactory
/// @notice Deploys one Lodestar router per launchpad pool at an address anyone can predict from the token
/// and quote. One factory per launchpad: everything launchpad specific comes from its fee-source adapter.
/// Activation on a two-step launchpad (Ascend, Boxa):
///   1. `predict(token, quote)` to get the router address.
///   2. On the launchpad: propose the router as the new creator.
///   3. Here: `deploy(params)`. In one transaction this creates the router, its Exile holder-rewards
///      pool and its Sandfall Team Treasury stream, accepts the creator role, optionally enrols the
///      listing set-aside and, if the dev chose so, locks the creator role to the router forever.
/// On a one-step launchpad (Kleos, Eleos) the order flips, because the role moves in one call and nothing
/// on chain would prove who sent it: `deploy(params)` first, then `transferCreator(token, router)` on the
/// launchpad. The router earns from the moment the role arrives.
/// The dev keeps the dev-buy tokens; only the creator fee stream moves to the router.
contract LodestarFactory {
    struct DeployParams {
        address token;
        address quote; // address(0) = native HYPE
        ILodestar.Config cfg;
        address treasuryRecipient;
        uint32 treasuryWindow;
        IExile.Tier[] tiers;
        bool enrolListing;
        uint256 listingCap;
        /// @dev When the creator role unlocks: 0 = no lock, type(uint64).max = locked for good.
        uint64 creatorLockUntil;
    }

    address public immutable implementation;
    /// @notice The launchpad's fee-source adapter, handed to every router made here.
    IFeeSource public immutable source;
    IExile public immutable exile;
    ISandfall public immutable sandfall;

    /// @notice Names the successor factory for upgrades and the default swapper for new activations. A multisig
    /// in production, separate from every steward, so no single key can start an upgrade.
    address public owner;
    /// @notice The owner role's next holder until it accepts (0 = no handover pending).
    address public pendingOwner;
    address public defaultSwapper;
    /// @notice When the default swapper last changed. A new default only applies to deploys 12 hours
    /// later, so it can't be swapped in between a dev's `transferCreator` and `deploy`.
    uint64 public defaultSwapperSetAt;
    uint64 public constant DEFAULT_SWAPPER_DELAY = 12 hours;
    /// @notice A newer Monarchy factory that routers made here may move their creator role to, once each,
    /// with 7 days' notice. The owner names it, and each router's steward still has to propose the move.
    /// 0 = none.
    address public successor;
    mapping(address token => address) public lodestarOf;
    address[] public allLodestars;

    event LodestarDeployed(
        address indexed token,
        bytes32 indexed poolId,
        address lodestar,
        address indexed steward,
        uint256 exilePoolId,
        uint256 treasuryStreamId
    );
    event DefaultSwapperSet(address swapper);
    event SuccessorSet(address successor);
    event OwnerTransferStarted(address indexed next);
    event OwnerTransferred(address indexed previous, address indexed next);

    error NotPoolCreator();
    error TransferCreatorFirst();
    error OnlyOwner();
    error ZeroAddress();
    error WrongTokenOrder();
    error DefaultSwapperJustChanged();
    error AlreadyDeployed();
    error NotPendingOwner();
    /// @dev The coin pays holders dividends inside the token and the adapter doesn't know how Exile can claim them.
    error HoldersSplitActive();
    error NoListingDesk();
    error NotStranded();

    /// @dev Where a deploy lands, resolved before `_deploy`.
    struct Target {
        bytes32 poolId;
        address hook;
        bool tokenIs0;
        address lodestar;
        address steward;
        bool twoStep;
    }

    constructor(
        address implementation_,
        IFeeSource source_,
        IExile exile_,
        ISandfall sandfall_,
        address defaultSwapper_,
        address owner_
    ) {
        if (owner_ == address(0)) revert ZeroAddress();
        implementation = implementation_;
        source = source_;
        exile = exile_;
        sandfall = sandfall_;
        owner = owner_;
        defaultSwapper = defaultSwapper_;
        emit OwnerTransferred(address(0), owner_);
        emit DefaultSwapperSet(defaultSwapper_);
    }

    /// @notice The router address and pool id for a token, before or after deployment. Reverts for a pair the
    /// launchpad's adapter doesn't support.
    function predict(address token, address quote) public view returns (address lodestar, bytes32 poolId) {
        (poolId,,) = source.resolve(token, quote);
        lodestar = Clones.predictDeterministicAddress(implementation, poolId, address(this));
    }

    /// @notice Activate a Lodestar. The caller must be the pool's current creator on the launchpad. On a
    /// two-step launchpad they must already have proposed the predicted router as creator; on a one-step one
    /// they hand the role over after this call. Send about 6M gas when `enrolListing` is set (Ascend's desk
    /// checks a gas floor).
    /// The steward of the router that holds the role may also call it to deploy that router's upgrade target
    /// here (see `Lodestar.proposeUpgrade`): during the 7 day notice on one-step launchpads, after
    /// `executeUpgrade` on two-step ones.
    function deploy(DeployParams calldata p) external returns (address lodestar) {
        Target memory t = _target(p, msg.sender);
        lodestar = t.lodestar;
        address creator = source.creator(p.token, t.poolId);
        if (creator != msg.sender && !_upgradeFrom(p.token, t, creator)) revert NotPoolCreator();
        if (t.twoStep && source.pendingCreator(p.token, t.poolId) != lodestar) revert TransferCreatorFirst();
        _deploy(p, t);
    }

    /// @notice For a one-step launchpad where the creator handed the role to the predicted router before deploying
    /// it: the role now sits at an address with no code and nothing on chain says who sent it, so `deploy` can't
    /// tell the creator from anyone else. The owner deploys it with the settings the creator asks for, after
    /// checking off chain who handed the role over.
    function rescueDeploy(DeployParams calldata p, address steward) external returns (address lodestar) {
        if (msg.sender != owner) revert OnlyOwner();
        if (steward == address(0)) revert ZeroAddress();
        Target memory t = _target(p, steward);
        lodestar = t.lodestar;
        if (t.twoStep || source.creator(p.token, t.poolId) != lodestar) revert NotStranded();
        _deploy(p, t);
    }

    function _target(DeployParams calldata p, address steward) internal view returns (Target memory t) {
        (t.poolId, t.hook, t.tokenIs0) = source.resolve(p.token, p.quote);
        t.lodestar = Clones.predictDeterministicAddress(implementation, t.poolId, address(this));
        t.steward = steward;
        t.twoStep = source.handover() == IFeeSource.Handover.TwoStep;
    }

    function _deploy(DeployParams calldata p, Target memory t) internal {
        address lodestar = t.lodestar;
        bytes32 poolId = t.poolId;
        if (p.treasuryRecipient == address(0)) revert ZeroAddress();
        // the pool id sorts the pair, so check token and quote weren't passed the wrong way round
        if (t.tokenIs0 != (p.token < p.quote)) revert WrongTokenOrder();
        // a second deploy would collide on CREATE2, which burns all the gas sent; fail cheaply instead.
        // To take the role back after it left, hand it to the existing router (and call its acceptCreator).
        if (lodestar.code.length != 0) revert AlreadyDeployed();
        address desk = source.desk();
        if (p.enrolListing && desk == address(0)) revert NoListingDesk();
        // a coin that pays its holders dividends by balance pays them to Exile for every locked coin; Exile can
        // only pass them on to lockers if it knows the claim. It is set whenever the adapter knows one, since
        // anyone can top up a coin's dividends whatever its split says.
        (address claimTarget, bytes4 claimSelector) = source.dividendClaim(p.token);
        if (claimSelector == bytes4(0) && source.holdersShareBps(p.token, poolId) > 0) {
            revert HoldersSplitActive();
        }

        Clones.cloneDeterministic(implementation, poolId);
        // the router administers the reward pool, so tier changes stay with whoever is steward
        ILodestar.InitParams memory ip;
        ip.exilePoolId = exile.createPool(p.token, p.quote, p.tiers, lodestar);
        ip.treasuryStreamId =
            sandfall.createRolling(p.quote, p.treasuryRecipient, p.treasuryWindow, lodestar, false);
        if (claimSelector != bytes4(0)) {
            exile.setHarvest(p.token, ip.exilePoolId, claimTarget, claimSelector);
        }

        ip.config = p.cfg;
        if (ip.config.swapper == address(0)) {
            if (block.timestamp < defaultSwapperSetAt + DEFAULT_SWAPPER_DELAY) {
                revert DefaultSwapperJustChanged();
            }
            ip.config.swapper = defaultSwapper;
        }
        ip.source = address(source);
        ip.hook = t.hook;
        ip.desk = desk;
        ip.exile = address(exile);
        ip.sandfall = address(sandfall);
        ip.poolId = poolId;
        ip.token = p.token;
        ip.quote = p.quote;
        ip.tokenIs0 = t.tokenIs0;
        ip.burnSink = source.burnSink(p.token);
        ip.steward = t.steward;
        ILodestar(lodestar).initialize(ip);
        if (t.twoStep) ILodestar(lodestar).acceptCreator();
        if (p.enrolListing) ILodestar(lodestar).enrollListing(p.listingCap);
        if (p.creatorLockUntil > 0) ILodestar(lodestar).lockCreatorRole(p.creatorLockUntil);

        lodestarOf[p.token] = lodestar;
        allLodestars.push(lodestar);
        emit LodestarDeployed(p.token, poolId, lodestar, t.steward, ip.exilePoolId, ip.treasuryStreamId);
    }

    /// @dev True when `creator` is a router whose steward is the caller and whose upgrade points at `lodestar`:
    /// still pending on a one-step launchpad (the role moves only once the new router exists), already executed
    /// on a two-step one (the launchpad then shows `lodestar` as pending creator).
    function _upgradeFrom(address token, Target memory t, address creator) internal view returns (bool) {
        address lodestar = t.lodestar;
        if (creator == lodestar || creator.code.length == 0) return false;
        try ILodestar(creator).steward() returns (address s) {
            if (s != msg.sender) return false;
        } catch {
            return false;
        }
        if (t.twoStep) return source.pendingCreator(token, t.poolId) == lodestar;
        try ILodestar(creator).upgradeTarget() returns (address target) {
            return target == lodestar;
        } catch {
            return false;
        }
    }

    function allLodestarsLength() external view returns (uint256) {
        return allLodestars.length;
    }

    // ---------------------------------------------------------------- owner

    /// @notice Buyback route used by future deploys that don't pick one. Existing routers are unaffected.
    function setDefaultSwapper(address swapper) external {
        if (msg.sender != owner) revert OnlyOwner();
        defaultSwapper = swapper;
        defaultSwapperSetAt = uint64(block.timestamp);
        emit DefaultSwapperSet(swapper);
    }

    /// @notice Name the newer factory that routers made here may upgrade to (0 clears it). Naming one moves
    /// nothing: a router's steward has to propose the move, and it waits 7 days. Changing or clearing the
    /// successor stops every pending move to the old one.
    function setSuccessor(address next) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (next == address(this)) revert ZeroAddress();
        successor = next;
        emit SuccessorSet(next);
    }

    /// @notice Start handing the owner role to `next`, which takes it with `acceptOwner`, so a mistyped address
    /// can't strand the role. Naming another address replaces a pending handover; 0 cancels it.
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
}
