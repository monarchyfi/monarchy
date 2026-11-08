// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LodestarFactory} from "./LodestarFactory.sol";
import {ILodestar} from "./interfaces/ILodestar.sol";
import {IAscendV5EscrowFactory} from "./interfaces/IAscendV5.sol";
import {AscendV5FeeSource} from "./sources/AscendV5FeeSource.sol";

interface IWrappedNative {
    function deposit() external payable;
}

/// @title AscendV5Launcher
/// @notice Launches a coin on Ascend v5 with its Lodestar router as the fee owner from the first trade. In one
/// transaction it launches a "Pays creator" (Vanilla) coin through Ascend's EscrowFactory with the escrow's recipient
/// set to the coin's predicted router, then has the Monarchy factory deploy that router for the caller. There is no
/// hand-off, so Ascend's 48 hour wait for a recipient change never applies and no creator fee is ever paid to a
/// wallet. Coins launched this way never accept Ascend's community takeovers (`cto` is off), so the router keeps the
/// role for as long as its own creator lock says.
/// The caller is the router's steward and gets the dev buy. Ascend's app only lets a coin's fee wallet publish its
/// art, and here that is the router, so the coin's picture, description and links are kept here (`profileOf`) for
/// Monarchy's site; the steward can change them. The picture is the file itself, stored on chain as the code of a
/// small data contract (the site shrinks it to a 256 pixel WebP first), so it needs no server and can't go missing.
contract AscendV5Launcher is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev `fee` in pips, as Ascend takes it: 10_000 (1%) to 100_000 (10%). `quote` is WHYPE, USDC or KNTQ.
    /// `salt` is the caller's own: the launcher mixes in the caller's address, so nobody can copy a pending launch
    /// to take its coin address.
    struct Coin {
        string name;
        string symbol;
        address quote;
        uint24 fee;
        uint256 devBuyQuote;
        uint256 minDevOut;
        bytes32 salt;
    }

    /// @dev Untrusted content for display: `image` is the picture file's bytes (Monarchy's site only shows WebP, PNG,
    /// JPEG and GIF, by their magic bytes, and only https links).
    struct Profile {
        bytes image;
        string description;
        string website;
        string twitter;
        string telegram;
    }

    /// @dev A profile as kept: the picture lives in a data contract's code.
    struct Kept {
        address image;
        string description;
        string website;
        string twitter;
        string telegram;
    }

    /// @notice The tag of Ascend's launch statement (`ascend.disclosure.v1`), appended after the launch call.
    bytes32 public constant DISCLOSURE_TAG = "ascend.disclosure.v1";
    uint256 public constant MAX_PLAN = 500;
    uint256 public constant MAX_DESCRIPTION = 1000;
    uint256 public constant MAX_LINK = 300;
    /// @notice The largest picture, in bytes: a data contract's code holds at most 24,576 bytes.
    uint256 public constant MAX_IMAGE = 24_000;

    LodestarFactory public immutable factory;
    AscendV5FeeSource public immutable source;
    IAscendV5EscrowFactory public immutable escrowFactory;
    /// @notice WHYPE: a HYPE-paired dev buy may be sent as native HYPE, which is wrapped first.
    address public immutable wrappedNative;

    /// @notice Who launched a coin here (0 for coins launched anywhere else).
    mapping(address token => address) public launcherOf;
    mapping(address token => Kept) internal _profiles;

    event CoinLaunched(
        address indexed token, bytes32 indexed poolId, address indexed creator, address lodestar, uint24 fee
    );
    event ProfileSet(address indexed token, address indexed by);

    error WrongDeployParams();
    error LaunchMismatch();
    error BadValue();
    error TooLong();
    error NotLaunchedHere();
    error NotSteward();
    error ZeroAddress();
    error ImageNotStored();

    constructor(LodestarFactory factory_, address wrappedNative_) {
        if (address(factory_) == address(0) || wrappedNative_ == address(0)) revert ZeroAddress();
        factory = factory_;
        source = AscendV5FeeSource(address(factory_.source()));
        escrowFactory = source.escrowFactory();
        wrappedNative = wrappedNative_;
    }

    /// @notice The coin, pool and router a `launch` by `creator` with `c` would create. Fill `DeployParams.token`
    /// with this token.
    function predict(address creator, Coin calldata c)
        public
        view
        returns (address token, bytes32 poolId, address lodestar)
    {
        (, token) = escrowFactory.predict(address(this), _params(creator, c), _route(address(0), creator));
        poolId = keccak256(abi.encode(source.poolKey(token, c.quote)));
        lodestar = Clones.predictDeterministicAddress(factory.implementation(), poolId, address(factory));
    }

    /// @notice Launch `c` on Ascend v5 with its router as fee owner, and deploy the router with `d` (its `token` is
    /// `predict`'s, its `quote` is `c.quote`). `plan` is an optional launch statement for Ascend's coin page
    /// (1–500 characters; empty = none). The dev buy is pulled from the caller, or sent as HYPE for a WHYPE pair;
    /// what it doesn't spend comes back in the quote. Send about 7M gas, plus about 5M for a full-size picture.
    function launch(
        Coin calldata c,
        LodestarFactory.DeployParams calldata d,
        Profile calldata profile,
        string calldata plan
    ) external payable nonReentrant returns (address token, bytes32 poolId, address lodestar) {
        (token, poolId, lodestar) = predict(msg.sender, c);
        if (d.token != token || d.quote != c.quote) revert WrongDeployParams();
        if (bytes(plan).length > MAX_PLAN) revert TooLong();
        _checkProfile(profile);

        _launch(c, token, poolId, lodestar, plan);

        if (factory.deployLaunched(d, msg.sender) != lodestar) revert LaunchMismatch();
        launcherOf[token] = msg.sender;
        _keep(token, profile, false);
        emit CoinLaunched(token, poolId, msg.sender, lodestar, c.fee);
    }

    /// @notice The coin's picture, description and links, as its steward set them.
    function profileOf(address token) external view returns (Profile memory p) {
        Kept storage k = _profiles[token];
        p.image = _read(k.image);
        p.description = k.description;
        p.website = k.website;
        p.twitter = k.twitter;
        p.telegram = k.telegram;
    }

    /// @notice Change the profile of a coin launched here. Only the coin's router's current steward. An empty
    /// `image` keeps the current picture unless `removeImage` is set.
    function setProfile(address token, Profile calldata profile, bool removeImage) external {
        if (launcherOf[token] == address(0)) revert NotLaunchedHere();
        if (ILodestar(factory.lodestarOf(token)).steward() != msg.sender) revert NotSteward();
        _checkProfile(profile);
        _keep(token, profile, removeImage);
    }

    function _keep(address token, Profile calldata p, bool removeImage) internal {
        Kept storage k = _profiles[token];
        if (p.image.length != 0) k.image = _store(p.image);
        else if (removeImage) k.image = address(0);
        k.description = p.description;
        k.website = p.website;
        k.twitter = p.twitter;
        k.telegram = p.telegram;
        emit ProfileSet(token, msg.sender);
    }

    /// @dev Deploys `data` as the code of a contract that can't be called (it starts with STOP), the way SSTORE2 does:
    /// 200 gas a byte instead of 20,000 a word in storage.
    function _store(bytes calldata data) internal returns (address pointer) {
        bytes memory code = abi.encodePacked(hex"61", uint16(data.length + 1), hex"80600a3d393df300", data);
        assembly ("memory-safe") {
            pointer := create(0, add(code, 32), mload(code))
        }
        if (pointer == address(0)) revert ImageNotStored();
    }

    function _read(address pointer) internal view returns (bytes memory data) {
        if (pointer == address(0)) return data;
        uint256 size = pointer.code.length - 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 32), 1, size)
        }
    }

    /// @dev Pull the dev buy, launch with `lodestar` as the escrow's recipient, check Ascend made the predicted coin
    /// and pool, and refund what the dev buy didn't spend.
    function _launch(Coin calldata c, address token, bytes32 poolId, address lodestar, string calldata plan)
        internal
    {
        IERC20 q = IERC20(c.quote);
        uint256 before = q.balanceOf(address(this));
        _pullDevBuy(c);
        bytes memory data = abi.encodeCall(
            IAscendV5EscrowFactory.launch, (_params(msg.sender, c), _route(lodestar, msg.sender))
        );
        if (bytes(plan).length != 0) data = bytes.concat(data, abi.encode(DISCLOSURE_TAG, "", plan));
        (bool ok, bytes memory ret) = address(escrowFactory).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        (address launched, bytes32 launchedPool,) = abi.decode(ret, (address, bytes32, address));
        if (launched != token || launchedPool != poolId) revert LaunchMismatch();
        if (c.devBuyQuote != 0) q.forceApprove(address(escrowFactory), 0);
        uint256 left = q.balanceOf(address(this)) - before;
        if (left != 0) q.safeTransfer(msg.sender, left);
    }

    function _pullDevBuy(Coin calldata c) internal {
        if (msg.value != 0) {
            if (c.quote != wrappedNative || msg.value != c.devBuyQuote) revert BadValue();
            IWrappedNative(wrappedNative).deposit{value: msg.value}();
        } else if (c.devBuyQuote != 0) {
            IERC20(c.quote).safeTransferFrom(msg.sender, address(this), c.devBuyQuote);
        }
        if (c.devBuyQuote != 0) IERC20(c.quote).forceApprove(address(escrowFactory), c.devBuyQuote);
    }

    function _params(address creator, Coin calldata c)
        internal
        pure
        returns (IAscendV5EscrowFactory.LaunchParams memory p)
    {
        p = IAscendV5EscrowFactory.LaunchParams({
            name: c.name,
            symbol: c.symbol,
            quote: c.quote,
            devBuyQuote: c.devBuyQuote,
            minDevOut: c.minDevOut,
            salt: keccak256(abi.encode(creator, c.salt)),
            creator: address(0),
            fee: c.fee,
            builderFee: 0
        });
    }

    function _route(address recipient, address dev)
        internal
        pure
        returns (IAscendV5EscrowFactory.Route memory)
    {
        return IAscendV5EscrowFactory.Route({recipient: recipient, dev: dev, builder: address(0), cto: false});
    }

    function _checkProfile(Profile calldata p) internal pure {
        if (
            p.image.length > MAX_IMAGE || bytes(p.description).length > MAX_DESCRIPTION
                || bytes(p.website).length > MAX_LINK || bytes(p.twitter).length > MAX_LINK
                || bytes(p.telegram).length > MAX_LINK
        ) revert TooLong();
    }
}
