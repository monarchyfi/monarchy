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
import {MonarchTiers} from "../src/libraries/MonarchTiers.sol";
import {MockArbSys} from "../src/mocks/MockArbSys.sol";

/// @notice Activate a Lodestar for a coin on Eleos, Kleos or Boxa, run by the coin's creator (PRIVATE_KEY is the
/// address the launchpad records as creator). LAUNCHPAD=eleos|kleos|boxa, TOKEN=<coin>, TREASURY=<Team Treasury
/// recipient, permanent>. The order follows the launchpad, so a creator can't get it wrong:
/// - Boxa (two-step, like Ascend): `proposeCreator(poolId, router)` on the hook, then `factory.deploy`, which
///   accepts the role.
/// - Eleos and Kleos (one-step): `factory.deploy` first, then `transferCreator(coin, router)` on the hook. If the
///   second transaction doesn't land, run the script again: it sees the router and only hands the role over.
///   On Eleos the fees the hook holds for the coin follow the role, so the script first pays the creator what
///   they earned (`process` if due, then `payCreator`) unless CLAIM_FIRST=false. Kleos and Boxa keep earned fees
///   by address, so the creator claims those on the launchpad whenever they like.
/// Defaults are MONARCH's: 20% buyback and burn / 50% lockers / 30% Team Treasury streamed over 7 days,
/// Peasant-Knight-Duke-Monarch tiers, creator role locked to the router forever. Overrides: BURN_BPS, HOLDERS_BPS,
/// TREASURY_BPS, MAX_SLIPPAGE_BPS, TOKEN_TO_HOLDERS, TREASURY_WINDOW (seconds), LOCK_FOREVER=false, and SWAPPER:
/// unset uses the factory's default (none in phase 1, so the buyback share waits in reserve), `v4` the V4Swapper
/// recorded for the coin's pool manager, or an address.
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

        // reverts with UnsupportedHook or QuoteUnsupported for a coin the adapter can't serve
        (address predicted, bytes32 poolId) = factory.predict(token, address(0));
        (address hook, V4FeeSource.HookInfo memory info) = source.hookOf(token);
        bool twoStep = source.handover() == IFeeSource.Handover.TwoStep;
        address creator = source.creator(token, poolId);
        LodestarFactory.DeployParams memory p = _params(token, pad, info.poolManager);
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

    function _params(address token, Pad memory pad, address pm)
        internal
        view
        returns (LodestarFactory.DeployParams memory p)
    {
        string memory s = vm.envOr("SWAPPER", string(""));
        address swapper;
        if (keccak256(bytes(s)) == keccak256("v4")) {
            swapper = _swapperFor(pad, pm);
            require(swapper != address(0), "no V4Swapper recorded for this coin's pool manager");
        } else if (bytes(s).length != 0) {
            swapper = vm.parseAddress(s);
        }
        p.token = token;
        p.quote = address(0); // native HYPE
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
