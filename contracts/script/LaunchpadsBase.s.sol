// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseScript} from "./Base.s.sol";
import {console2} from "forge-std/Script.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {ILodestar} from "../src/interfaces/ILodestar.sol";
import {MonarchTiers} from "../src/libraries/MonarchTiers.sol";

/// @notice Monarchy on the Uniswap v4 launchpads of Elysium mainnet (Ascend v5, Volta, ElysPump, Boxa, Kleos, Montra):
/// the hook registries the adapters start with, and `deployments/launchpads/<chainId>.json`, which records one shared core
/// (Exile, Sandfall, the Lodestar implementation, the price observer) plus an adapter, a factory and a buyback
/// swapper per pool manager for each launchpad (a V4Swapper, or an AscendV5Swapper on Ascend). The routers themselves are not listed: each factory's `allLodestars` is the list.
/// The file sits in its own folder because the website loads every `deployments/*.json` as an Ascend deployment.
/// LAUNCHPADS_FILE points the scripts at another file under deployments/ (rehearsals on a local fork).
abstract contract LaunchpadsBase is BaseScript {
    uint256 internal constant ELYSIUM_MAINNET = 99901;
    uint256 internal constant PADS = 6;
    /// @dev Ascend v5's launchpad (every launch pool's hook) and BurnSink, from Ascend's contract registry.
    address internal constant ASCEND_V5_LAUNCHPAD = 0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC;
    address internal constant ASCEND_V5_BURN_SINK = 0x9F0b0e3B362937b07Cd1E869b50687961e0c7741;
    address internal constant ASCEND_V5_WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;
    /// @dev The launchpads in the website's order.
    uint256 internal constant ASCEND = 0;
    uint256 internal constant VOLTA = 1;
    uint256 internal constant ELYSPUMP = 2;
    uint256 internal constant BOXA = 3;
    uint256 internal constant KLEOS = 4;
    uint256 internal constant MONTRA = 5;

    struct Pad {
        address source; // the launchpad's IFeeSource adapter
        address factory; // its LodestarFactory
        address[] poolManagers; // the Uniswap v4 PoolManagers its hooks use
        address[] swappers; // one buyback swapper per pool manager, in the same order
        address launcher; // Ascend v5 only: the AscendV5Launcher that launches coins straight into a router
    }

    struct Launchpads {
        address owner; // the multisig that owns the factories, the adapters and Exile
        address exile;
        address sandfall;
        address lodestarImpl;
        address observer;
        uint256 startBlock;
        Pad[6] pads; // ascend, volta, elyspump, boxa, kleos, montra
    }

    function _padName(uint256 i) internal pure returns (string memory) {
        if (i == ASCEND) return "ascend";
        if (i == VOLTA) return "volta";
        if (i == ELYSPUMP) return "elyspump";
        if (i == BOXA) return "boxa";
        if (i == KLEOS) return "kleos";
        if (i == MONTRA) return "montra";
        revert("no such launchpad");
    }

    /// @dev LAUNCHPAD=ascend|volta|elyspump|boxa|kleos|montra
    function _padIndex(string memory name) internal pure returns (uint256) {
        for (uint256 i; i < PADS; ++i) {
            if (keccak256(bytes(name)) == keccak256(bytes(_padName(i)))) return i;
        }
        revert("LAUNCHPAD must be ascend, volta, elyspump, boxa, kleos or montra");
    }

    /// @notice The hooks each adapter knows at deploy, with their kinds, and the pool managers they swap on. Read
    /// from Elysium mainnet on November 4, 2026 (ElysPump on November 8, Volta and Montra on November 9; see
    /// docs/launchpads.md, and Ascend v5 in docs/ascend-v5.md). A new hook generation is added later by the adapter's owner with `addHook`, without a
    /// redeploy.
    function _registry(uint256 i)
        internal
        pure
        returns (address[] memory hooks, uint8[] memory kinds, address[] memory pms)
    {
        if (i == ASCEND) {
            // Ascend v5 (ascendlaunch.xyz): the launchpad is every pool's hook and the adapter finds pools through
            // its escrow factory, so there is no hook list. Its pools run on the official pool manager.
            hooks = new address[](0);
            kinds = new uint8[](0);
            pms = new address[](1);
            pms[0] = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
        } else if (i == VOLTA) {
            // Volta (volta.family): its PositionManager is every pool's hook, on the official pool manager
            hooks = new address[](1);
            kinds = new uint8[](1);
            (hooks[0], kinds[0]) = (0x3aB88DDc3CF2A012af88B60828edb4553697E5dC, 1);
            pms = new address[](1);
            pms[0] = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
        } else if (i == ELYSPUMP) {
            // ElysPump (elysp.com): its v2 hook on ElysPump's own pool manager and its v3 hook (the same contract)
            // on the official one. Its first launchpad runs on Uniswap v3 and isn't supported.
            hooks = new address[](2);
            kinds = new uint8[](2);
            (hooks[0], kinds[0]) = (0xe11CaFA5901B0aaB51eB78251488400f9e4320Cc, 1);
            (hooks[1], kinds[1]) = (0xBAcF71Bf02b8cfE171853C5eC4A060Ba2Ac1E0cc, 1);
            pms = new address[](2);
            pms[0] = 0x5fb015a49f5b35073f9Ce01C2aDb287A75F89600;
            pms[1] = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
        } else if (i == BOXA) {
            // Boxa (boxa.club): the main hook, the pairs and meme-pairs hooks, and the uni launcher's hook, which
            // runs on the official pool manager
            hooks = new address[](4);
            kinds = new uint8[](4);
            (hooks[0], kinds[0]) = (0xBCc1f22d137C1D98DFa5548E4d4261D7AeE06acC, 1);
            (hooks[1], kinds[1]) = (0xB3E25CDf4a2f42e7f37aB3aE43Bfb90EE8052AcC, 2);
            (hooks[2], kinds[2]) = (0xD2f8e16ba85e9D160724e893B3ebCe53D00E6Acc, 2);
            (hooks[3], kinds[3]) = (0x00C002Cdae688F39a90CF2AD74c59421C9502aCC, 3);
            pms = new address[](2);
            pms[0] = 0x06C63714fBf1F5753017123E2FcfdEde4540B2c4;
            pms[1] = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
        } else if (i == KLEOS) {
            // Kleos (thekleos.xyz): hooks A and B single-quote, hook C multi-quote
            hooks = new address[](3);
            kinds = new uint8[](3);
            (hooks[0], kinds[0]) = (0x0c835e6A51717a514144d95c7F0a1C640179E0Cc, 1);
            (hooks[1], kinds[1]) = (0x772AccB053609D361593345e361D2a6854Ede8cc, 1);
            (hooks[2], kinds[2]) = (0xD5068e7f4e2D70d5eFbaC6fD28A8407252E1EAcC, 2);
            pms = new address[](1);
            pms[0] = 0xb308B5df891c300a5f5a5b8fdBC30108bA842490;
        } else if (i == MONTRA) {
            // Montra (montramarkets.xyz): its launch hook, the one its registry lists, on the official pool manager
            hooks = new address[](1);
            kinds = new uint8[](1);
            (hooks[0], kinds[0]) = (0x6b1216A40B65c83e9c9e18a562C446697B8cf8EC, 1);
            pms = new address[](1);
            pms[0] = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
        } else {
            revert("no such launchpad");
        }
    }

    function _lpPath() internal view returns (string memory) {
        string memory custom = vm.envOr("LAUNCHPADS_FILE", string(""));
        if (bytes(custom).length != 0) return string.concat(vm.projectRoot(), "/", custom);
        return string.concat(vm.projectRoot(), "/deployments/launchpads/", vm.toString(block.chainid), ".json");
    }

    function _lpLoad() internal view returns (Launchpads memory d) {
        string memory path = _lpPath();
        if (!vm.exists(path)) return d;
        string memory j = vm.readFile(path);
        d.owner = _a(j, ".owner");
        d.exile = _a(j, ".exile");
        d.sandfall = _a(j, ".sandfall");
        d.lodestarImpl = _a(j, ".lodestarImpl");
        d.observer = _a(j, ".observer");
        if (vm.keyExistsJson(j, ".startBlock")) d.startBlock = vm.parseJsonUint(j, ".startBlock");
        for (uint256 i; i < PADS; ++i) {
            string memory p = string.concat(".launchpads.", _padName(i));
            if (!vm.keyExistsJson(j, p)) continue;
            d.pads[i].source = _a(j, string.concat(p, ".source"));
            d.pads[i].factory = _a(j, string.concat(p, ".factory"));
            d.pads[i].poolManagers = vm.parseJsonAddressArray(j, string.concat(p, ".poolManagers"));
            d.pads[i].swappers = vm.parseJsonAddressArray(j, string.concat(p, ".swappers"));
            d.pads[i].launcher = _a(j, string.concat(p, ".launcher"));
        }
    }

    function _lpSave(Launchpads memory d) internal {
        string memory pads;
        for (uint256 i; i < PADS; ++i) {
            // a launchpad this run skipped (Ascend on a fork from before v5) isn't listed
            if (d.pads[i].factory == address(0)) continue;
            string memory k = _padName(i);
            vm.serializeAddress(k, "source", d.pads[i].source);
            vm.serializeAddress(k, "factory", d.pads[i].factory);
            vm.serializeAddress(k, "poolManagers", d.pads[i].poolManagers);
            if (d.pads[i].launcher != address(0)) vm.serializeAddress(k, "launcher", d.pads[i].launcher);
            string memory one = vm.serializeAddress(k, "swappers", d.pads[i].swappers);
            pads = vm.serializeString("launchpads", k, one);
        }
        string memory r = "root";
        vm.serializeUint(r, "chainId", block.chainid);
        vm.serializeAddress(r, "owner", d.owner);
        vm.serializeAddress(r, "exile", d.exile);
        vm.serializeAddress(r, "sandfall", d.sandfall);
        vm.serializeAddress(r, "lodestarImpl", d.lodestarImpl);
        vm.serializeAddress(r, "observer", d.observer);
        vm.serializeUint(r, "startBlock", d.startBlock);
        string memory out = vm.serializeString(r, "launchpads", pads);
        string memory path = _lpPath();
        vm.createDir(string.concat(vm.projectRoot(), "/deployments/launchpads"), true);
        vm.writeJson(out, path);
        console2.log("wrote", path);
    }

    /// @dev The V4Swapper `pad` keeps for `pm`, or 0.
    function _swapperFor(Pad memory pad, address pm) internal pure returns (address) {
        for (uint256 i; i < pad.poolManagers.length; ++i) {
            if (pad.poolManagers[i] == pm && i < pad.swappers.length) return pad.swappers[i];
        }
        return address(0);
    }

    /// @dev Whether a launchpad's factory has to be an Exile registrar: only when its coins can pay holders
    /// dividends that Exile harvests (ElysPump, Boxa, Kleos). Ascend v5 coins pay none, Volta pays holders as
    /// wallets only and a Montra coin paying its holders can't be activated, so those factories never ask.
    function _needsRegistrar(uint256 i) internal pure returns (bool) {
        return i == ELYSPUMP || i == BOXA || i == KLEOS;
    }

    /// @dev A router's settings from the environment (see ActivateLaunchpad for the variables and defaults).
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
        p.quote = quote; // native HYPE on Volta, ElysPump, Boxa, Kleos and Montra; an ERC-20 on Ascend v5
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

    function _has(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    function _a(string memory j, string memory key) private view returns (address) {
        return vm.keyExistsJson(j, key) ? vm.parseJsonAddress(j, key) : address(0);
    }
}
