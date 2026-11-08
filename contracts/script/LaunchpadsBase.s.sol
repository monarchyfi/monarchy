// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseScript} from "./Base.s.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Monarchy on the Uniswap v4 launchpads of Elysium mainnet (Eleos, Kleos, Boxa, Ascend v5): the hook
/// registries the adapters start with, and `deployments/launchpads/<chainId>.json`, which records one shared core
/// (Exile, Sandfall, the Lodestar implementation, the price observer) plus an adapter, a factory and a buyback
/// swapper per pool manager for each launchpad (a V4Swapper, or an AscendV5Swapper on Ascend). The routers themselves are not listed: each factory's `allLodestars` is the list.
/// The file sits in its own folder because the website loads every `deployments/*.json` as an Ascend deployment.
/// LAUNCHPADS_FILE points the scripts at another file under deployments/ (rehearsals on a local fork).
abstract contract LaunchpadsBase is BaseScript {
    uint256 internal constant ELYSIUM_MAINNET = 99901;
    uint256 internal constant PADS = 4;
    /// @dev Ascend v5's launchpad (every launch pool's hook) and BurnSink, from Ascend's contract registry.
    address internal constant ASCEND_V5_LAUNCHPAD = 0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC;
    address internal constant ASCEND_V5_BURN_SINK = 0x9F0b0e3B362937b07Cd1E869b50687961e0c7741;
    uint256 internal constant ASCEND = 3;

    struct Pad {
        address source; // the launchpad's IFeeSource adapter
        address factory; // its LodestarFactory
        address[] poolManagers; // the Uniswap v4 PoolManagers its hooks use
        address[] swappers; // one buyback swapper per pool manager, in the same order
    }

    struct Launchpads {
        address owner; // the multisig that owns the factories, the adapters and Exile
        address exile;
        address sandfall;
        address lodestarImpl;
        address observer;
        uint256 startBlock;
        Pad[4] pads; // eleos, kleos, boxa, ascend
    }

    function _padName(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "eleos";
        if (i == 1) return "kleos";
        if (i == 2) return "boxa";
        if (i == 3) return "ascend";
        revert("no such launchpad");
    }

    /// @dev LAUNCHPAD=eleos|kleos|boxa|ascend
    function _padIndex(string memory name) internal pure returns (uint256) {
        for (uint256 i; i < PADS; ++i) {
            if (keccak256(bytes(name)) == keccak256(bytes(_padName(i)))) return i;
        }
        revert("LAUNCHPAD must be eleos, kleos, boxa or ascend");
    }

    /// @notice The hooks each adapter knows at deploy, with their kinds, and the pool managers they swap on. Read
    /// from Elysium mainnet on November 4, 2026 (see docs/launchpads.md; Ascend v5 in docs/ascend-v5.md). A new hook generation is added later by
    /// the adapter's owner with `addHook`, without a redeploy.
    function _registry(uint256 i)
        internal
        pure
        returns (address[] memory hooks, uint8[] memory kinds, address[] memory pms)
    {
        if (i == 0) {
            // Eleos (eleos.fun): hooks 1, 2 and 3 share one ABI
            hooks = new address[](3);
            kinds = new uint8[](3);
            (hooks[0], kinds[0]) = (0x6BcDf22D303C029805a733270E450C99E1DbAACC, 1);
            (hooks[1], kinds[1]) = (0xb0dcb98508173C29AD57Df444EE3e91fc681aacc, 1);
            (hooks[2], kinds[2]) = (0x8680965555DCEa2a4c0Ed3a29e59a8AA424E6acC, 1);
            pms = new address[](1);
            pms[0] = 0x5c54A7293D96B11a29A0256eE8dfdBC3059637Da;
        } else if (i == 1) {
            // Kleos (thekleos.xyz): hooks A and B single-quote, hook C multi-quote
            hooks = new address[](3);
            kinds = new uint8[](3);
            (hooks[0], kinds[0]) = (0x0c835e6A51717a514144d95c7F0a1C640179E0Cc, 1);
            (hooks[1], kinds[1]) = (0x772AccB053609D361593345e361D2a6854Ede8cc, 1);
            (hooks[2], kinds[2]) = (0xD5068e7f4e2D70d5eFbaC6fD28A8407252E1EAcC, 2);
            pms = new address[](1);
            pms[0] = 0xb308B5df891c300a5f5a5b8fdBC30108bA842490;
        } else if (i == 2) {
            // Boxa (boxa.club): the main hook, the pairs and meme-pairs hooks, and the uni launcher's hook, which
            // runs on a pool manager of its own
            hooks = new address[](4);
            kinds = new uint8[](4);
            (hooks[0], kinds[0]) = (0xBCc1f22d137C1D98DFa5548E4d4261D7AeE06acC, 1);
            (hooks[1], kinds[1]) = (0xB3E25CDf4a2f42e7f37aB3aE43Bfb90EE8052AcC, 2);
            (hooks[2], kinds[2]) = (0xD2f8e16ba85e9D160724e893B3ebCe53D00E6Acc, 2);
            (hooks[3], kinds[3]) = (0x00C002Cdae688F39a90CF2AD74c59421C9502aCC, 3);
            pms = new address[](2);
            pms[0] = 0x06C63714fBf1F5753017123E2FcfdEde4540B2c4;
            pms[1] = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
        } else if (i == ASCEND) {
            // Ascend v5 (ascendlaunch.xyz): the launchpad is every pool's hook and the adapter finds pools through
            // its escrow factory, so there is no hook list. Its pools run on the same pool manager as Boxa's uni
            // launcher.
            hooks = new address[](0);
            kinds = new uint8[](0);
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
    /// dividends that Exile harvests. Ascend v5 coins pay none, so its factory never asks for the role.
    function _needsRegistrar(uint256 i) internal pure returns (bool) {
        return i != ASCEND;
    }

    function _has(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    function _a(string memory j, string memory key) private view returns (address) {
        return vm.keyExistsJson(j, key) ? vm.parseJsonAddress(j, key) : address(0);
    }
}
