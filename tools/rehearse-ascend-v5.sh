#!/usr/bin/env bash
# Dress rehearsal of Monarchy on Ascend v5 on a local anvil fork of Elysium mainnet. Sends nothing to the real
# chain: anvil forks it into a local node and every transaction goes there.
#
#   ELYSIUM_RPC_URL=https://rpc-live.boxa.club [FORK_BLOCK=<block>] tools/rehearse-ascend-v5.sh
#
# 1. DeployLaunchpads with anvil's first key, an anvil EOA standing in for the multisig (ALLOW_EOA_OWNER=true). It
#    deploys all four launchpads; this rehearsal only uses Ascend's, which needs no Exile registrar.
# 2. A live Vanilla coin (3% fee, quoted in WHYPE) has its escrow's recipient moved (impersonated, with Ascend's own
#    48 hour wait) to an anvil key, which then runs ActivateLaunchpad as the creator would: propose the router,
#    deploy it with Monarchy's AscendV5Swapper. A second run before the wait is over must send nothing.
# 3. Traders buy, and tools/keeper-launchpads.sh runs during the wait: it must leave the router alone.
# 4. 48 hours later the keeper accepts the hand-off; what Ascend credited before stays the creator's. After more
#    trades the keeper distributes: the escrow's WHYPE credit is split to Exile lockers, the Team Treasury stream and
#    the buyback (bought and burned at Ascend's BurnSink, or kept in reserve while Ascend's average price lags).
# 5. The other way onto Ascend: LaunchAscend launches a new coin through Monarchy's AscendV5Launcher (named on the
#    factory by the owner in step 1) with a picture file stored on chain, and its router as fee wallet from the first
#    trade, so there is no wait. A second run sends nothing; after trades the keeper distributes and no creator fee
#    ever reaches a wallet.
# The deployments file goes to deployments/launchpads/rehearsal.json (git-ignored) and the anvil log to $TMPDIR.
# Needs forge, cast, anvil and jq. KEEP_ANVIL=1 leaves the node running at the end (for the website, with
# VITE_LAUNCHPADS_REHEARSAL=1 and VITE_MAINNET_RPC_URL pointing at it).
set -euo pipefail

: "${ELYSIUM_RPC_URL:?set ELYSIUM_RPC_URL, for example https://rpc-live.boxa.club}"
PORT=${PORT:-8548}
RPC=http://127.0.0.1:$PORT
export LAUNCHPADS_FILE=deployments/launchpads/rehearsal.json
FILE=$LAUNCHPADS_FILE
LOG=${TMPDIR:-/tmp}/rehearse-ascend-v5-anvil.log

# anvil's well-known test keys
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
CREATOR_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
TRADER_KEY=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
KEEPER_KEY=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
addr() { cast wallet address --private-key "$1"; }
OWNER=$(addr $OWNER_KEY)
CREATOR=$(addr $CREATOR_KEY)
TRADER=$(addr $TRADER_KEY)
TREASURY=0x000000000000000000000000000000000000bEEF

COIN=0x086f8850FBC3101c4Bdc6932c3D5f639cb34D2DF # a Vanilla coin at a 3% fee, paired with WHYPE
WHYPE=0xbA876237B0F021A6c6D852d6c26E107997cC5E81
BURN_SINK=0x9F0b0e3B362937b07Cd1E869b50687961e0c7741

FORK=(--fork-url "$ELYSIUM_RPC_URL")
[ -z "${FORK_BLOCK:-}" ] || FORK+=(--fork-block-number "$FORK_BLOCK")
anvil "${FORK[@]}" --port "$PORT" --silent >"$LOG" 2>&1 &
ANVIL=$!
if [ "${KEEP_ANVIL:-}" != "1" ]; then trap 'kill $ANVIL 2>/dev/null || true' EXIT; fi
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break || sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "99901" ] || { echo "the fork is not Elysium mainnet"; exit 1; }
rm -f "$FILE"

# Elysium is an Arbitrum Orbit chain; anvil has no ArbSys precompile, which Kleos's hooks ask about their caller
ARBSYS=$(forge inspect contracts/src/mocks/MockArbSys.sol:MockArbSys deployedBytecode)
cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 "$ARBSYS" --rpc-url "$RPC" >/dev/null

send() {
  local out
  out=$(cast send "$@" --gas-limit 5000000 --json --rpc-url "$RPC")
  [ "$(jq -r .status <<<"$out")" = "0x1" ] || { echo "reverted: $*"; exit 1; }
}
call() { cast call "$@" --rpc-url "$RPC"; }
num() { awk '{print $1}'; }
warp() {
  cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
}
script() { forge script "contracts/script/$1" --rpc-url "$RPC" --broadcast --slow -q; }
keeper() { RPC_URL=$RPC KEEPER_PRIVATE_KEY=$KEEPER_KEY tools/keeper-launchpads.sh "$FILE" 99901; }
check() { if eval "$2"; then echo "ok: $1"; else echo "FAILED: $1"; exit 1; fi; }

echo "== 1. DeployLaunchpads"
PRIVATE_KEY=$DEPLOYER_KEY FACTORY_OWNER=$OWNER ALLOW_EOA_OWNER=true script DeployLaunchpads.s.sol
SOURCE=$(jq -r .launchpads.ascend.source "$FILE")
FACTORY=$(jq -r .launchpads.ascend.factory "$FILE")
SWAPPER=$(jq -r '.launchpads.ascend.swappers[0]' "$FILE")
EXILE=$(jq -r .exile "$FILE")
LAUNCHER=$(jq -r .launchpads.ascend.launcher "$FILE")
check "the Ascend pad is recorded" '[ "$FACTORY" != null ] && [ "$(cast code "$FACTORY" --rpc-url "$RPC")" != 0x ]'
check "its launcher is deployed" '[ "$LAUNCHER" != null ] && [ "$(cast code "$LAUNCHER" --rpc-url "$RPC")" != 0x ]'
# the deployer isn't the owner, so DeployLaunchpads printed this call for the multisig
send "$FACTORY" "setLauncher(address)" "$LAUNCHER" --private-key "$OWNER_KEY"
check "the owner named the launcher on the factory" '[ "$(call "$FACTORY" "launcher()(address)")" = "$LAUNCHER" ]'
check "its factory is not an Exile registrar (it doesn't need to be)" \
  '[ "$(call "$EXILE" "isRegistrar(address)(bool)" "$FACTORY")" = false ]'

echo "== 2. Move the coin's escrow to the rehearsal creator, then ActivateLaunchpad"
read -r ROUTER POOL < <(call "$FACTORY" "predict(address,address)(address,bytes32)" "$COIN" "$WHYPE" | xargs)
ESCROW=$(call "$SOURCE" "escrowOf(bytes32)(address)" "$POOL")
REAL=$(call "$ESCROW" "recipient()(address)")
cast rpc anvil_impersonateAccount "$REAL" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$REAL" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
send "$ESCROW" "proposeRecipient(address)" "$CREATOR" --from "$REAL" --unlocked
warp 172801
send "$ESCROW" "acceptRecipient()" --private-key "$CREATOR_KEY"
check "the rehearsal creator is the recipient" '[ "$(call "$ESCROW" "recipient()(address)")" = "$CREATOR" ]'

PRIVATE_KEY=$CREATOR_KEY LAUNCHPAD=ascend TOKEN=$COIN TREASURY=$TREASURY SWAPPER=v4 script ActivateLaunchpad.s.sol
check "the router is deployed" '[ "$(cast code "$ROUTER" --rpc-url "$RPC")" != 0x ]'
check "the hand-off to it is pending" '[ "$(call "$ESCROW" "pendingRecipient()(address)")" = "$ROUTER" ]'
check "it isn't the creator yet" '[ "$(call "$ROUTER" "isCreator()(bool)")" = false ]'
check "its lock is set but doesn't bind yet" '[ "$(call "$ROUTER" "creatorRoleLocked()(bool)")" = false ]'
check "its buyback goes through the AscendV5Swapper" \
  'call "$ROUTER" "config()((uint16,uint16,uint16,address,uint16,bool))" | grep -qi "$SWAPPER"'
NONCE=$(cast nonce "$CREATOR" --rpc-url "$RPC")
PRIVATE_KEY=$CREATOR_KEY LAUNCHPAD=ascend TOKEN=$COIN TREASURY=$TREASURY script ActivateLaunchpad.s.sol
check "a second run during the wait sends nothing" '[ "$(cast nonce "$CREATOR" --rpc-url "$RPC")" = "$NONCE" ]'

echo "== 3. Trading, and the keeper during the wait"
send "$WHYPE" "deposit()" --value 200ether --private-key "$TRADER_KEY"
send "$WHYPE" "approve(address,uint256)" "$SWAPPER" "$(cast max-uint)" --private-key "$TRADER_KEY"
buy() { send "$SWAPPER" "buyExactIn(bytes32,uint256,uint256,address)" "$POOL" "$1" 0 "$TRADER" --private-key "$TRADER_KEY"; }
for _ in $(seq 1 5); do
  buy 10ether
  warp 360
done
keeper
check "the keeper left the router waiting" '[ "$(call "$ROUTER" "isCreator()(bool)")" = false ]'

echo "== 4. 48 hours later: the keeper accepts, traders buy, the keeper distributes"
warp 172801
keeper
check "the router holds the creator role" '[ "$(call "$ROUTER" "isCreator()(bool)")" = true ]'
check "the creator lock now binds" '[ "$(call "$ROUTER" "creatorRoleLocked()(bool)")" = true ]'
check "what Ascend credited before the hand-off stayed with the creator" \
  '[ "$(call "$ESCROW" "claimable(address)(uint256)" "$CREATOR" | num)" != 0 ]'
# trades after the hand-off, a few minutes apart so Ascend's average price keeps up with them
for _ in $(seq 1 20); do
  buy 2ether
  warp 360
done
check "Ascend credits the router now" '[ "$(call "$ESCROW" "claimable(address)(uint256)" "$ROUTER" | num)" != 0 ]'
BEFORE=$(call "$ESCROW" "claimable(address)(uint256)" "$ROUTER" | num)
OUT=$(keeper)
echo "$OUT"
check "the escrow paid the router inside distribute (no ClaimFailed)" '! grep -q ClaimFailed <<<"$OUT"'
LEFT=$(call "$ESCROW" "claimable(address)(uint256)" "$ROUTER" | num)
# a buyback pays the pool's fee like any buy, so a sliver of it comes back as a new credit
check "the router's credit was paid out (what's left is the buyback's own fee coming back)" \
  '[ $(( ${#BEFORE} - ${#LEFT} )) -ge 2 ]' # at least 100 times smaller
HOLD=$(call "$ROUTER" "totalHoldersQuote()(uint256)" | num)
TREAS=$(call "$ROUTER" "totalTreasuryQuote()(uint256)" | num)
BUYQ=$(call "$ROUTER" "totalBuybackQuote()(uint256)" | num)
RESERVE=$(call "$ROUTER" "buybackReserve()(uint256)" | num)
BURNED=$(call "$ROUTER" "totalBuybackTokensBurned()(uint256)" | num)
echo "routed to lockers $HOLD, to the treasury $TREAS, bought back with $BUYQ (burned $BURNED), in reserve $RESERVE (WHYPE wei)"
check "lockers were paid in WHYPE" '[ "$HOLD" != 0 ]'
check "the Team Treasury stream was paid" '[ "$TREAS" != 0 ]'
check "the buyback share was bought back or kept" '[ "$BUYQ" != 0 ] || [ "$RESERVE" != 0 ]'
if [ "$BURNED" != 0 ]; then
  check "bought coins went to Ascend's BurnSink" '[ "$(call "$COIN" "balanceOf(address)(uint256)" "$BURN_SINK" | num)" != 0 ]'
fi
keeper >/dev/null
echo "ok: a second keeper run right after goes through"

echo "== 5. Launch a new coin through Monarchy: the router is the fee wallet from the first trade"
# a real picture file, stored on chain with the launch
IMAGE_HEX=0x$(od -An -v -tx1 web/public/apple-touch-icon.png | tr -d ' \n')
launch() {
  PRIVATE_KEY=$CREATOR_KEY NAME="Rehearsal Monarch" SYMBOL=RMON TREASURY=$TREASURY SWAPPER=v4 FEE=5 \
    DEV_BUY=1000000000000000000 IMAGE_HEX=$IMAGE_HEX DESCRIPTION="Launched through Monarchy." WEBSITE=https://example.com \
    PLAN="The first buy is the team's." script LaunchAscend.s.sol
}
launch
N=$(call "$FACTORY" "allLodestarsLength()(uint256)" | num)
NEW=$(call "$FACTORY" "allLodestars(uint256)(address)" $((N - 1)))
TOKEN=$(call "$NEW" "token()(address)")
NEWPOOL=$(call "$NEW" "poolId()(bytes32)")
NEWESCROW=$(call "$SOURCE" "escrowOf(bytes32)(address)" "$NEWPOOL")
check "the new coin's escrow pays its router" '[ "$(call "$NEWESCROW" "recipient()(address)")" = "$NEW" ]'
check "with nothing pending" '[ "$(call "$NEWESCROW" "pendingRecipient()(address)")" = 0x0000000000000000000000000000000000000000 ]'
check "and no community takeovers" '[ "$(call "$NEWESCROW" "ctoRegistry()(address)")" = 0x0000000000000000000000000000000000000000 ]'
check "the router holds the creator role at once" '[ "$(call "$NEW" "isCreator()(bool)")" = true ]'
check "its lock binds at once" '[ "$(call "$NEW" "creatorRoleLocked()(bool)")" = true ]'
check "the creator is its steward" '[ "$(call "$NEW" "steward()(address)")" = "$CREATOR" ]'
check "the creator got the first buy" '[ "$(call "$TOKEN" "balanceOf(address)(uint256)" "$CREATOR" | num)" != 0 ]'
check "the pool fee is the 5% asked for" '[ "$(call "$(call "$SOURCE" "launchpad()(address)")" "currentFee(bytes32)(uint24)" "$NEWPOOL" | num)" = 50000 ]'
check "the launcher keeps the coin's picture, byte for byte" 'call "$LAUNCHER" "profileOf(address)((bytes,string,string,string,string))" "$TOKEN" | grep -qi "($IMAGE_HEX,"'
NONCE=$(cast nonce "$CREATOR" --rpc-url "$RPC")
launch
check "a second run sends nothing" '[ "$(cast nonce "$CREATOR" --rpc-url "$RPC")" = "$NONCE" ]'
for _ in $(seq 1 10); do
  send "$SWAPPER" "buyExactIn(bytes32,uint256,uint256,address)" "$NEWPOOL" 5ether 0 "$TRADER" --private-key "$TRADER_KEY"
  warp 360
done
H0=$(call "$NEW" "totalHoldersQuote()(uint256)" | num)
keeper >/dev/null
check "the keeper routed the new coin's fees to lockers" '[ "$(call "$NEW" "totalHoldersQuote()(uint256)" | num)" != "$H0" ]'
check "and to the Team Treasury stream" '[ "$(call "$NEW" "totalTreasuryQuote()(uint256)" | num)" != 0 ]'
check "no creator fee ever reached a wallet" '[ "$(call "$NEWESCROW" "claimable(address)(uint256)" "$CREATOR" | num)" = 0 ]'
echo "rehearsal passed: router $ROUTER for coin $COIN, and router $NEW for the coin $TOKEN launched through Monarchy"
