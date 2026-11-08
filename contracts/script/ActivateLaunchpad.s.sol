// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchpadsBase} from "./LaunchpadsBase.s.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Exile} from "../src/Exile.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {ILodestar} from "../src/interfaces/ILodestar.sol";
import {IFeeSource} from "../src/interfaces/IFeeSource.sol";
import {IEleosHook, IKleosHook, IBoxaHook} from "../src/interfaces/ILaunchpadHooks.sol";
import {V4FeeSource} from "../src/sources/V4FeeSource.sol";
import {AscendV5FeeSource} from "../src/sources/AscendV5FeeSource.sol";
import {IAscendV5Escrow} from "../src/interfaces/IAscendV5.sol";
import {MonarchTiers} from "../src/libraries/MonarchTiers.sol";
import {MockArbSys} from "../src/mocks/MockArbSys.sol";

/// @notice Activate a Lodestar for a coin on Eleos, Kleos, Boxa or Ascend v5, run by the coin's creator (PRIVATE_KEY
/// is the address the launchpad records as creator). LAUNCHPAD=eleos|kleos|boxa|ascend, TOKEN=<coin>,
/// TREASURY=<Team Treasury recipient, permanent>. The order follows the launchpad, so a creator can't get it wrong:
/// - Boxa (two-step, like Ascend): `proposeCreator(poolId, router)` on the hook, then `factory.deploy`, which
///   accepts the role.
/// - Eleos and Kleos (one-step): `factory.deploy` first, then `transferCreator(coin, router)` on the hook. If the
///   second transaction doesn't land, run the script again: it sees the router and only hands the role over.
///   On Eleos the fees the hook holds for the coin follow the role, so the script first pays the creator what
///   they earned (`process` if due, then `payCreator`) unless CLAIM_FIRST=false. Kleos and Boxa keep earned fees
///   by address, so the creator claims those on the launchpad whenever they like.
/// - Ascend v5 (two-step with a 48 hour wait): `proposeRecipient(router)` on the pool's escrow, then
///   `factory.deploy`, which leaves the hand-off pending. Run the script again once the 48 hours are over (any
///   funded key will do then) and it calls the router's `acceptCreator()`. QUOTE=whype|usdc|kntq|<address> picks
///   the pair; unset, the script finds the one Ascend pool the coin has. Credits Ascend already paid the creator
///   stay theirs (`escrow.claim(wallet)`); fees Ascend still holds until graduation go to the router.
/// Defaults are MONARCH's: 20% buyback and burn / 50% lockers / 30% Team Treasury streamed over 7 days,
/// Peasant-Knight-Duke-Monarch tiers, creator role locked to the router forever. Overrides: BURN_BPS, HOLDERS_BPS,
/// TREASURY_BPS, MAX_SLIPPAGE_BPS, TOKEN_TO_HOLDERS, TREASURY_WINDOW (seconds), LOCK_FOREVER=false, and SWAPPER:
/// unset uses the factory's default (none in phase 1, so the buyback share waits in reserve), `v4` the swapper
/// recorded for the coin's pool manager (the AscendV5Swapper on Ascend), or an address.
/// If the role already sits at the predicted router address with no router there (sent before deploying), or at
/// another coin's router from the same factory (a mixed-up address), nothing on chain proves who sent it: the
/// script prints the `rescueDeploy` calldata for the factory owner instead.
contract ActivateLaunchpad is LaunchpadsBase {
    function run() external {
        // forge runs the script in its own EVM, which has no ArbSys; Kleos's hooks call it. This stand-in only
        // exists in that local run (on chain the real precompile answers), so on Kleos pass --skip-simulation too:
        // forge's second, on-chain-state simulation doesn't carry it.
        if (block.chainid == ELYSIUM_MAINNET) vm.etch(address(0x64), type(MockArbSys).runtimeCode);
        Launchpads memory d = _lpLoad();
        uint256 li = _padIndex(vm.envString("LAUNCHPAD"));
        Pad memory pad = d.pads[li];
        require(_has(pad.factory), "no factory for this launchpad in the deployments file; run DeployLaunchpads");
        LodestarFactory factory = LodestarFactory(pad.factory);
        V4FeeSource source = V4FeeSource(pad.source);
        address token = vm.envAddress("TOKEN");
        uint256 pk = _deployerKey();
        address me = vm.addr(pk);
        if (li == ASCEND) return _activateAscend(pad, factory, token, pk, me);

        // reverts with UnsupportedHook or QuoteUnsupported for a coin the adapter can't serve
        (address predicted, bytes32 poolId) = factory.predict(token, address(0));
        (address hook, V4FeeSource.HookInfo memory info) = source.hookOf(token);
        bool twoStep = source.handover() == IFeeSource.Handover.TwoStep;
        address creator = source.creator(token, poolId);
        LodestarFactory.DeployParams memory p = _params(token, address(0), pad, info.poolManager);
        console2.log("coin", token);
        console2.log("hook", hook);
        console2.log("predicted Lodestar", predicted);
        console2.log("creator on the launchpad", creator);

        if (predicted.code.length != 0) {
            require(!Lodestar(payable(predicted)).isCreator(), "already active: the router holds the creator role");
            require(!twoStep, "the router exists without the role; the creator proposes it again and it accepts");
            require(creator == me, "PRIVATE_KEY is not the coin's creator on the launchpad");
            console2.log("the router exists; handing the role over");
            vm.startBroadcast(pk);
            IKleosHook(hook).transferCreator(token, predicted); // same call on Eleos and Kleos
            vm.stopBroadcast();
            _check(predicted);
            return;
        }
        if (!twoStep && (creator == predicted || _otherCoinsRouter(factory, creator, token))) {
            if (creator == predicted) {
                console2.log("the role was sent to the router address before the router existed.");
            } else {
                console2.log("the role was sent to another coin's router:", creator);
            }
            console2.log("the factory owner deploys it with rescueDeploy; this is the calldata for the multisig,");
            console2.log("to the factory", address(factory), "with this creator as steward:", me);
            console2.logBytes(abi.encodeCall(LodestarFactory.rescueDeploy, (p, me)));
            return;
        }
        require(creator == me, "PRIVATE_KEY is not the coin's creator on the launchpad");
        (, bytes4 claimSelector) = source.dividendClaim(token);
        require(
            claimSelector != bytes4(0) || source.holdersShareBps(token, poolId) == 0,
            "this coin pays holders a share Exile can't pass on to lockers (Kleos hook C); it can't be activated"
        );
        require(
            claimSelector == bytes4(0) || Exile(payable(d.exile)).isRegistrar(address(factory)),
            "the factory isn't an Exile registrar yet; run FinishLaunchpads"
        );
        address swapper = p.cfg.swapper == address(0) ? factory.defaultSwapper() : p.cfg.swapper;
        console2.log("buyback swapper (0 = buyback share waits in reserve)", swapper);

        vm.startBroadcast(pk);
        if (twoStep) {
            require(li == 2, "two-step activation is written for Boxa");
            if (source.pendingCreator(token, poolId) != predicted) IBoxaHook(hook).proposeCreator(poolId, predicted);
            require(factory.deploy(p) == predicted, "deployed somewhere else");
        } else {
            if (li == 0 && vm.envOr("CLAIM_FIRST", true)) _claimEleos(hook, token);
            require(factory.deploy(p) == predicted, "deployed somewhere else");
            IKleosHook(hook).transferCreator(token, predicted);
        }
        vm.stopBroadcast();
        _check(predicted);
    }

    /// @dev Ascend v5: propose, deploy, and once the escrow's 48 hours are over, accept. Each run does what is left.
    function _activateAscend(Pad memory pad, LodestarFactory factory, address token, uint256 pk, address me)
        internal
    {
        address quote = _ascendQuote(factory, token);
        (address predicted, bytes32 poolId) = factory.predict(token, quote);
        IAscendV5Escrow escrow = _ascendReport(AscendV5FeeSource(pad.source), token, quote, predicted, poolId);
        if (escrow.recipient() == predicted) {
            console2.log("already active: the router is the escrow's recipient");
            return;
        }
        if (predicted.code.length != 0 && escrow.pendingRecipient() == predicted) {
            _acceptWhenReady(escrow, predicted, pk);
            return;
        }
        require(escrow.recipient() == me, "PRIVATE_KEY is not the recipient on the coin's Ascend escrow");
        _proposeAndDeploy(factory, escrow, _params(token, quote, pad, pad.poolManagers[0]), predicted, pk);
        console2.log("proposed and deployed; the router can accept at", uint256(escrow.recipientReadyAt()));
        console2.log("then run this script again (any funded key), or call acceptCreator() on the router");
    }

    function _ascendReport(
        AscendV5FeeSource source,
        address token,
        address quote,
        address predicted,
        bytes32 poolId
    ) internal view returns (IAscendV5Escrow escrow) {
        escrow = source.escrowOf(poolId);
        console2.log("coin", token);
        console2.log("quote", quote);
        console2.log("escrow", address(escrow));
        console2.log("predicted Lodestar", predicted);
        console2.log("recipient on the escrow", escrow.recipient());
        console2.log("pool fee in pips (10000 = 1%)", uint256(source.launchpad().currentFee(poolId)));
        if (source.takeoverRegistry(poolId) != address(0)) {
            console2.log("note: this pool opted in to Ascend's community takeovers; an approved");
            console2.log("takeover replaces the escrow's recipient, router and creator lock included");
        }
    }

    function _acceptWhenReady(IAscendV5Escrow escrow, address predicted, uint256 pk) internal {
        uint256 readyAt = escrow.recipientReadyAt();
        if (block.timestamp < readyAt) {
            console2.log("the router waits for Ascend's 48 hours; it can accept at (unix time)", readyAt);
            console2.log("seconds left", readyAt - block.timestamp);
            return;
        }
        console2.log("the 48 hours are over; accepting");
        vm.startBroadcast(pk);
        Lodestar(payable(predicted)).acceptCreator();
        vm.stopBroadcast();
        _check(predicted);
    }

    function _proposeAndDeploy(
        LodestarFactory factory,
        IAscendV5Escrow escrow,
        LodestarFactory.DeployParams memory p,
        address predicted,
        uint256 pk
    ) internal {
        console2.log("buyback swapper (0 = factory default)", p.cfg.swapper);
        console2.log("factory default (0 = buyback share waits in reserve)", factory.defaultSwapper());
        vm.startBroadcast(pk);
        if (escrow.pendingRecipient() != predicted) escrow.proposeRecipient(predicted);
        if (predicted.code.length == 0) require(factory.deploy(p) == predicted, "deployed somewhere else");
        vm.stopBroadcast();
    }

    /// @dev QUOTE=whype|usdc|kntq|<address>, or the one quote the coin has an Ascend v5 pool with.
    function _ascendQuote(LodestarFactory factory, address token) internal view returns (address quote) {
        address[3] memory known = [
            0xbA876237B0F021A6c6D852d6c26E107997cC5E81, // WHYPE
            0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65, // USDC
            0xe45a355d9e9cAd2aD85F2d03E3eE3102A036acF0 // KNTQ
        ];
        string memory q = vm.envOr("QUOTE", string(""));
        bytes32 h = keccak256(bytes(q));
        if (h == keccak256("whype")) return known[0];
        if (h == keccak256("usdc")) return known[1];
        if (h == keccak256("kntq")) return known[2];
        if (bytes(q).length != 0) return vm.parseAddress(q);
        for (uint256 i; i < known.length; ++i) {
            try factory.predict(token, known[i]) {
                require(quote == address(0), "the coin has pools with more than one quote; set QUOTE");
                quote = known[i];
            } catch {}
        }
        require(quote != address(0), "no Ascend v5 pool for this coin against WHYPE, USDC or KNTQ; set QUOTE");
    }

    /// @dev True when `holder` is a router `factory` made for a coin other than `token`.
    function _otherCoinsRouter(LodestarFactory factory, address holder, address token) internal view returns (bool) {
        if (holder.code.length == 0) return false;
        try Lodestar(payable(holder)).token() returns (IERC20 other) {
            return address(other) != token && factory.lodestarOf(address(other)) == holder;
        } catch {
            return false;
        }
    }

    /// @dev Pays the Eleos creator what the hook holds for them before the role (and that balance) moves.
    function _claimEleos(address hook, address token) internal {
        (bool due,,,) = IEleosHook(hook).processable(token);
        if (due) IEleosHook(hook).process(token);
        if (IEleosHook(hook).book(token).creatorOwed > 0) IEleosHook(hook).payCreator(token);
    }

    function _params(address token, address quote, Pad memory pad, address pm)
        internal
        view
        returns (LodestarFactory.DeployParams memory p)
    {
        string memory s = vm.envOr("SWAPPER", string(""));
        address swapper;
        if (keccak256(bytes(s)) == keccak256("v4")) {
            swapper = _swapperFor(pad, pm);
            require(swapper != address(0), "no swapper recorded for this coin's pool manager");
        } else if (bytes(s).length != 0) {
            swapper = vm.parseAddress(s);
        }
        p.token = token;
        p.quote = quote; // native HYPE on Eleos, Kleos and Boxa; an ERC-20 on Ascend v5
        p.cfg = ILodestar.Config({
            burnBps: uint16(vm.envOr("BURN_BPS", uint256(2_000))),
            holdersBps: uint16(vm.envOr("HOLDERS_BPS", uint256(5_000))),
            treasuryBps: uint16(vm.envOr("TREASURY_BPS", uint256(3_000))),
            swapper: swapper,
            maxSlippageBps: uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(1_000))),
            tokenToHolders: vm.envOr("TOKEN_TO_HOLDERS", true)
        });
        p.treasuryRecipient = vm.envAddress("TREASURY");
        p.treasuryWindow = uint32(vm.envOr("TREASURY_WINDOW", uint256(7 days)));
        p.tiers = MonarchTiers.defaults();
        p.creatorLockUntil = vm.envOr("LOCK_FOREVER", true) ? type(uint64).max : 0;
    }

    function _check(address lodestar) internal view {
        require(Lodestar(payable(lodestar)).isCreator(), "the router doesn't hold the creator role");
        console2.log("Lodestar active", lodestar);
    }
}
