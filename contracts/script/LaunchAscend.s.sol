// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchpadsBase} from "./LaunchpadsBase.s.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {AscendV5Launcher} from "../src/AscendV5Launcher.sol";

/// @notice Launch a new coin on Ascend v5 through Monarchy: the coin launches with its Lodestar router as fee wallet
/// and the router is created in the same transaction, so fees go through the split from the first trade and there
/// is no 48 hour hand-off (docs/ascend-v5.md, "Two ways onto Ascend"). Run by the creator (PRIVATE_KEY), who becomes
/// the router's steward and gets the first buy.
///   NAME, SYMBOL (permanent), TREASURY=<Team Treasury recipient, permanent>,
///   QUOTE=whype|usdc|kntq (default whype), FEE=1..10 (percent, default 3),
///   DEV_BUY=<first buy in the quote's base units, default 0> (on a WHYPE pair it is sent as HYPE and wrapped),
///   IMAGE=ipfs://<CID of the picture file, already pinned>, DESCRIPTION (up to 500 bytes), WEBSITE, TWITTER, TELEGRAM
///   (up to 200 bytes each; kept by the launcher for Monarchy's site, since Ascend only takes art from the fee wallet),
///   PLAN (an optional launch statement for Ascend's page),
///   SALT (default: from NAME and SYMBOL, so a second run finds the coin instead of launching another).
/// The router's settings use ActivateLaunchpad's variables: BURN_BPS, HOLDERS_BPS, TREASURY_BPS, MAX_SLIPPAGE_BPS,
/// TREASURY_WINDOW, LOCK_FOREVER, SWAPPER (`v4` = Monarchy's AscendV5Swapper). Send it with about 7M gas.
contract LaunchAscend is LaunchpadsBase {
    function run() external {
        Launchpads memory d = _lpLoad();
        Pad memory pad = d.pads[ASCEND];
        require(_has(pad.launcher), "no Ascend launcher in the deployments file; run DeployLaunchpads");
        AscendV5Launcher launcher = AscendV5Launcher(pad.launcher);
        LodestarFactory factory = LodestarFactory(pad.factory);
        require(
            factory.launcher() == address(launcher),
            "the factory's owner hasn't named the launcher yet (setLauncher)"
        );
        uint256 pk = _deployerKey();
        address me = vm.addr(pk);

        AscendV5Launcher.Coin memory c = _coin();
        (address token, bytes32 poolId, address router) = launcher.predict(me, c);
        if (router.code.length != 0) {
            console2.log("already launched: coin", token);
            console2.log("router", router);
            return;
        }
        LodestarFactory.DeployParams memory p = _params(token, c.quote, pad, pad.poolManagers[0]);
        p.cfg.tokenToHolders = false; // Ascend v5 pays no token-side fees
        bool native = c.quote == ASCEND_V5_WHYPE;

        vm.startBroadcast(pk);
        if (!native && c.devBuyQuote != 0) IERC20(c.quote).approve(address(launcher), c.devBuyQuote);
        launcher.launch{value: native ? c.devBuyQuote : 0}(c, p, _profile(), vm.envOr("PLAN", string("")));
        vm.stopBroadcast();

        require(Lodestar(payable(router)).isCreator(), "the router doesn't hold the creator role");
        console2.log("coin", token);
        console2.logBytes32(poolId);
        console2.log("router, the coin's fee wallet from the first trade", router);
    }

    function _coin() internal view returns (AscendV5Launcher.Coin memory c) {
        c.name = vm.envString("NAME");
        c.symbol = vm.envString("SYMBOL");
        string memory q = vm.envOr("QUOTE", string("whype"));
        bytes32 h = keccak256(bytes(q));
        if (h == keccak256("whype")) c.quote = ASCEND_V5_WHYPE;
        else if (h == keccak256("usdc")) c.quote = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
        else if (h == keccak256("kntq")) c.quote = 0xe45a355d9e9cAd2aD85F2d03E3eE3102A036acF0;
        else c.quote = vm.parseAddress(q);
        uint256 fee = vm.envOr("FEE", uint256(3));
        require(fee >= 1 && fee <= 10, "FEE is a whole percent from 1 to 10");
        c.fee = uint24(fee * 10_000);
        c.devBuyQuote = vm.envOr("DEV_BUY", uint256(0));
        // the pool is created inside the launch, so nobody can trade ahead of the first buy
        c.minDevOut = 0;
        c.salt = vm.envOr("SALT", keccak256(abi.encode(c.name, c.symbol)));
    }

    function _profile() internal view returns (AscendV5Launcher.Profile memory p) {
        p.image = vm.envOr("IMAGE", string(""));
        p.description = vm.envOr("DESCRIPTION", string(""));
        p.website = vm.envOr("WEBSITE", string(""));
        p.twitter = vm.envOr("TWITTER", string(""));
        p.telegram = vm.envOr("TELEGRAM", string(""));
    }
}
