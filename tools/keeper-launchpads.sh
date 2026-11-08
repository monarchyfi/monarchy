#!/usr/bin/env bash
# The keeper for Monarchy on Eleos, Kleos, Boxa and Ascend v5 (Elysium mainnet), as .github/workflows/distribute.yml
# runs it every 3 hours. tools/keeper-distribute.sh stays the keeper for the one Ascend router on the testnet.
#
#   RPC_URL=... KEEPER_PRIVATE_KEY=... tools/keeper-launchpads.sh [deployments/launchpads/99901.json] [chainId]
#
# - Sends nothing unless the RPC answers the expected chain id.
# - Walks every router the factories have made (`allLodestars`; creators activate without asking us), and for each
#   one:
#   1. when it doesn't hold its coin's creator role, calls its `acceptCreator()` if a dry run says that goes through
#      (an Ascend v5 activation once Ascend's 48 hour wait is over, or a Boxa hand-back); otherwise skips it (a
#      one-step activation whose handover never landed, a wait still running). Also skips it when its buyback
#      swapper is neither none nor a swapper from the deployments file: the creator picks the swapper, and the
#      keeper's gas shouldn't run code Monarchy didn't deploy;
#   2. catches its Exile pool up when it is more than CURRENT_WITHIN hours behind, MAX_BUCKETS_PER_CALL hours a
#      poke (at most 40), so the harvest and the payouts below have no hours left to walk;
#   3. calls `distribute()` when there is something to route: at least MIN_ROUTE_WEI of the quote (fees claimable
#      on the launchpad plus the router's balance; on Ascend v5 also the pool's fees not yet booked to its escrow,
#      which distribute collects first) or MIN_ROUTE_TOKENS of the coin, a parked payout, or a buyback reserve with
#      a swapper to spend it and no buyback in the last 30 minutes. MIN_ROUTE_WEI is in 18-decimal units; for a
#      quote with fewer decimals (USDC's 6) it is scaled down to match, at least 1. If the receipt says a holder
#      payout was parked (HoldersPayoutFailed or TokenHoldersPayoutFailed) it catches up and tries once more;
#   4. calls `Exile.harvest(coin)` when Exile has a harvest for the coin and a dry run says it brings in at least
#      MIN_HARVEST_WEI, so the dividends Exile earns on locked coins drip to the lockers. After distribute,
#      because on Eleos the distribute is what pays the holder share into the coin.
# - The minimums keep dust from costing a send every run: a native router takes HYPE from anyone, so 1 wei would
#   otherwise count as work. Below them nothing is lost, it waits for the next run. Defaults: MIN_ROUTE_WEI 1e15
#   (0.001 HYPE, about ten distributes' gas), MIN_ROUTE_TOKENS 1e18 (one whole coin at 18 decimals), and
#   MIN_HARVEST_WEI 1e13 (about one harvest's gas): only trades put dividends in a harvest, so the harvest's
#   minimum only stops sends that cost more than they bring. Set any of them to 1 to route anything.
# - Every send dry-runs first (`cast estimate`), refuses an estimate above MAX_GAS (default 4,000,000), sends with
#   30% headroom over the estimate, and checks the receipt (`cast send` alone exits 0 on a revert).
# - A router that fails is reported and the others still run; the script exits 1 at the end if any failed:
#   red is the point.
set -euo pipefail

FILE=${1:-deployments/launchpads/99901.json}
CHAIN_ID=${2:-${CHAIN_ID:-99901}}
MAX_GAS=${MAX_GAS:-4000000}
MIN_ROUTE_WEI=${MIN_ROUTE_WEI:-1000000000000000}     # 0.001 HYPE
MIN_ROUTE_TOKENS=${MIN_ROUTE_TOKENS:-1000000000000000000} # one whole coin at 18 decimals
MIN_HARVEST_WEI=${MIN_HARVEST_WEI:-10000000000000}     # 0.00001 HYPE
# An Ascend v5 escrow refuses to pay out with less than about 600,000 gas left (InsufficientCollectGas), and
# distribute carries on without the payout (ClaimFailed) rather than revert, so cast's estimate lands on a
# distribute that routes nothing. Distributes on Ascend routers go out with at least this much gas.
ASCEND_DISTRIBUTE_GAS=${ASCEND_DISTRIBUTE_GAS:-2000000}
CURRENT_WITHIN=6 # hours; the keeper runs every 3, so a healthy pool is never further behind
: "${RPC_URL:?set RPC_URL}"
: "${KEEPER_PRIVATE_KEY:?set KEEPER_PRIVATE_KEY}"
ZERO=0x0000000000000000000000000000000000000000

got=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$got" != "$CHAIN_ID" ]; then
  echo "::error::RPC answers chain id '$got', expected $CHAIN_ID. Not sending anything."
  exit 1
fi
if [ ! -f "$FILE" ]; then
  echo "::error::$FILE does not exist."
  exit 1
fi

call() { cast call "$@" --rpc-url "$RPC_URL"; }
lower() { tr '[:upper:]' '[:lower:]'; }
# ge <a> <b>: a >= b for unsigned decimals of any size (bash arithmetic stops at 2^63)
ge() {
  local a=$1 b=$2
  if [ ${#a} -ne ${#b} ]; then [ ${#a} -gt ${#b} ]; else [[ ! "$a" < "$b" ]]; fi
}
for v in MIN_ROUTE_WEI MIN_ROUTE_TOKENS MIN_HARVEST_WEI; do
  if ! [[ "${!v}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::$v must be a whole number of at least 1, got '${!v}'."
    exit 1
  fi
done

EXILE=$(jq -r '.exile // empty' "$FILE")
if ! [[ "$EXILE" =~ ^0x[0-9a-fA-F]{40}$ ]] || [ "$(cast code "$EXILE" --rpc-url "$RPC_URL")" = "0x" ]; then
  echo "::error::$FILE has no Exile with code on chain $CHAIN_ID."
  exit 1
fi
MAXB=$(cast to-dec "$(call "$EXILE" "MAX_BUCKETS_PER_CALL()")")
KEEPER=$(cast wallet address --private-key "$KEEPER_PRIVATE_KEY")
SWAPPERS=$(jq -r '[.launchpads[].swappers[]] | .[]' "$FILE" | lower)
# Ascend v5's launchpad, read from its adapter, for the pool fees distribute collects first (see 3. above)
ASCEND_LAUNCHPAD=""
ASCEND_SOURCE=$(jq -r '.launchpads.ascend.source // empty' "$FILE")
if [[ "$ASCEND_SOURCE" =~ ^0x[0-9a-fA-F]{40}$ ]] && [ "$ASCEND_SOURCE" != "$ZERO" ]; then
  ASCEND_LAUNCHPAD=$(call "$ASCEND_SOURCE" "launchpad()(address)")
fi
PARKED_TOPIC=$(cast sig-event "HoldersPayoutFailed(uint256)")
TOKEN_PARKED_TOPIC=$(cast sig-event "TokenHoldersPayoutFailed(uint256)")
CLAIM_FAILED_TOPIC=$(cast sig-event "ClaimFailed()")
LAST_RECEIPT=""
FAILED=0

# send <to> <signature> [args...]: dry run and gas check, then send with 30% over the estimate (or MIN_GAS when
# the caller sets it and it is more); the receipt must say success.
send() {
  local est gas out status hash
  if ! est=$(cast estimate "$@" --rpc-url "$RPC_URL" --private-key "$KEEPER_PRIVATE_KEY" 2>&1); then
    echo "dry run failed: $est"
    return 1
  fi
  if [ "$est" -gt "$MAX_GAS" ]; then
    echo "estimate $est is above MAX_GAS $MAX_GAS; not sending"
    return 1
  fi
  gas=$((est * 13 / 10))
  if [ -n "${MIN_GAS:-}" ] && [ "$gas" -lt "$MIN_GAS" ]; then gas=$MIN_GAS; fi
  if ! out=$(cast send "$@" --gas-limit "$gas" --json --rpc-url "$RPC_URL" \
    --private-key "$KEEPER_PRIVATE_KEY"); then
    echo "cast send failed before a receipt came back"
    return 1
  fi
  LAST_RECEIPT=$out
  status=$(jq -r '.status' <<<"$out")
  hash=$(jq -r '.transactionHash' <<<"$out")
  if [ "$status" != "0x1" ]; then
    echo "transaction $hash reverted (status $status)"
    return 1
  fi
  echo "transaction $hash confirmed, gas used $(cast to-dec "$(jq -r '.gasUsed' <<<"$out")")"
}

claim_failed() {
  jq -e --arg a "$CLAIM_FAILED_TOPIC" '[.logs[].topics[0]] | index($a) != null' <<<"$LAST_RECEIPT" >/dev/null
}

holders_parked() {
  jq -e --arg a "$PARKED_TOPIC" --arg b "$TOKEN_PARKED_TOPIC" \
    '[.logs[].topics[0]] | (index($a) != null) or (index($b) != null)' <<<"$LAST_RECEIPT" >/dev/null
}

# catch_up <exilePoolId>: poke the pool forward until it reports it is at most CURRENT_WITHIN hours behind.
catch_up() {
  local pid=$1 i
  for i in $(seq 1 40); do
    if [ "$(call "$EXILE" "poke(uint256,uint256)(bool)" "$pid" "$CURRENT_WITHIN")" = "true" ]; then
      return 0
    fi
    echo "Exile pool $pid is behind: poke $i of at most 40"
    send "$EXILE" "poke(uint256,uint256)" "$pid" "$MAXB" || return 1
  done
  echo "::warning::Exile pool $pid is still behind after 40 pokes"
}

# keep <router>: true when the keeper should run this router (see 1. above).
keep() {
  local r=$1 swapper
  if [ "$(call "$r" "isCreator()(bool)")" != "true" ]; then
    # a hand-off waiting on the router: send acceptCreator once a dry run says it goes through
    if ! cast estimate "$r" "acceptCreator()" --rpc-url "$RPC_URL" --private-key "$KEEPER_PRIVATE_KEY" >/dev/null 2>&1; then
      echo "does not hold the creator role (handover not done, or Ascend's 48 hour wait still running); skipping"
      return 1
    fi
    echo "acceptCreator(): the hand-off to this router can complete"
    send "$r" "acceptCreator()" || return 1
    if [ "$(call "$r" "isCreator()(bool)")" != "true" ]; then
      echo "::error::router $r accepted but still doesn't hold the creator role"
      return 1
    fi
  fi
  swapper=$(call "$r" "config()((uint16,uint16,uint16,address,uint16,bool))" | grep -oE '0x[0-9a-fA-F]{40}' | lower)
  if [ "$swapper" != "$ZERO" ] && ! grep -qx "$swapper" <<<"$SWAPPERS"; then
    echo "::warning::router $r uses swapper $swapper, which this deployment didn't make; skipping"
    return 1
  fi
}

# min_quote <router>: MIN_ROUTE_WEI in the router's quote units. It is set for 18 decimals (native HYPE, WHYPE);
# a quote with d < 18 decimals divides it by 10^(18-d), with d > 18 multiplies, and never goes below 1.
min_quote() {
  local r=$1 q d k m
  q=$(call "$r" "quote()(address)" | lower)
  [ "$q" != "$ZERO" ] || { echo "$MIN_ROUTE_WEI"; return; }
  d=$(call "$q" "decimals()(uint8)" | awk '{print $1}')
  m=$MIN_ROUTE_WEI
  if [ "$d" -gt 18 ]; then
    m=$m$(printf '0%.0s' $(seq 1 $((d - 18))))
  elif [ "$d" -lt 18 ]; then
    k=$((18 - d))
    if [ ${#m} -gt "$k" ]; then m=${m:0:${#m}-k}; else m=0; fi
  fi
  [[ "$m" =~ ^0*$ ]] && m=1
  echo "$m"
}

# ascend_pending <router> <min>: true when the router's Ascend v5 pool has at least <min> of fees the launchpad
# hasn't paid its escrow yet (accrued in the pool, or booked and not yet claimed); distribute collects and claims
# them first. The creator's credit is a part of these, so this only says there was trading since the last run.
ascend_pending() {
  local r=$1 min=$2 pid
  pid=$(call "$r" "poolId()(bytes32)")
  ge "$(call "$ASCEND_LAUNCHPAD" "accruedFees(bytes32)(uint256)" "$pid" | awk '{print $1}')" "$min" ||
    ge "$(call "$ASCEND_LAUNCHPAD" "creatorOwedQuote(bytes32)(uint256)" "$pid" | awk '{print $1}')" "$min"
}

# has_work <router> <pad>: true when distribute() would route something (see 3. above).
has_work() {
  local r=$1 pad=$2 preview tokenSide quoteTotal swapper minq
  if ! preview=$(call "$r" "previewDistribute()(uint256,uint256,uint256,uint256,uint256)" 2>/dev/null); then
    return 0 # can't tell; let distribute decide
  fi
  tokenSide=$(sed -n 1p <<<"$preview" | awk '{print $1}')
  quoteTotal=$(sed -n 2p <<<"$preview" | awk '{print $1}')
  minq=$(min_quote "$r")
  if ge "$tokenSide" "$MIN_ROUTE_TOKENS" || ge "$quoteTotal" "$minq"; then return 0; fi
  if [ "$pad" = "ascend" ] && [ -n "$ASCEND_LAUNCHPAD" ] && ascend_pending "$r" "$minq"; then return 0; fi
  if [ "$(call "$r" "holdersReserve()(uint256)" | awk '{print $1}')" != "0" ]; then return 0; fi
  if [ "$(call "$r" "treasuryReserve()(uint256)" | awk '{print $1}')" != "0" ]; then return 0; fi
  # a buyback reserve with a swapper, once the 30 minutes since the last buyback are up. Not gated on
  # maxBuyback(): distribute is what pokes the price observer, so a cold average only warms up if it runs
  swapper=$(call "$r" "config()((uint16,uint16,uint16,address,uint16,bool))" | grep -oE '0x[0-9a-fA-F]{40}' | lower)
  [ "$swapper" != "$ZERO" ] || return 1
  [ "$(call "$r" "buybackReserve()(uint256)" | awk '{print $1}')" != "0" ] || return 1
  [ "$(call "$r" "nextBuybackAt()(uint64)" | awk '{print $1}')" -le "$(cast block latest -f timestamp --rpc-url "$RPC_URL")" ]
}

# distribute_router <router> <exilePoolId> <pad>: distribute() when there is work, with one retry for a parked
# payout.
distribute_router() {
  local r=$1 pid=$2 pad=$3
  if ! has_work "$r" "$pad"; then
    echo "nothing to route"
    return 0
  fi
  local min=""
  [ "$pad" != "ascend" ] || min=$ASCEND_DISTRIBUTE_GAS
  echo "distribute()"
  MIN_GAS=$min send "$r" "distribute()" || return 1
  # the launchpad refused to pay the router this time; what it owes waits for the next run
  if claim_failed; then echo "::warning::router $r: the launchpad's payout failed inside distribute (ClaimFailed)"; fi
  if holders_parked; then
    echo "::warning::a holder payout was parked; catching Exile up, then one retry"
    catch_up "$pid" || return 1
    MIN_GAS=$min send "$r" "distribute()" || return 1
    if holders_parked; then
      echo "::error::a holder payout is still parked after a retry ($r)"
      return 1
    fi
  fi
}

# harvest_token <coin>: Exile.harvest when Exile has a harvest for the coin and a dry run says it brings in at
# least MIN_HARVEST_WEI.
harvest_token() {
  local token=$1 target got=0 out
  target=$(call "$EXILE" "harvestOf(address)(uint256,address,bytes4)" "$token" | sed -n 2p)
  [ "$target" != "$ZERO" ] || return 0
  if out=$(call "$EXILE" "harvest(address)(uint256)" "$token" --from "$KEEPER" 2>/dev/null); then
    got=$(awk '{print $1}' <<<"$out")
  fi
  if ! ge "$got" "$MIN_HARVEST_WEI"; then
    [ "$got" = "0" ] || echo "harvest would bring $got wei, under MIN_HARVEST_WEI; waiting"
    return 0
  fi
  echo "harvest brings $got wei of dividends to lockers"
  send "$EXILE" "harvest(address)" "$token"
}

# run_router <router> <pad>
run_router() {
  local r=$1 pad=$2 token pid rc=0
  keep "$r" || return 0
  token=$(call "$r" "token()(address)")
  pid=$(cast to-dec "$(call "$r" "exilePoolId()")")
  catch_up "$pid" || return 1

  # distribute before the harvest: on Eleos the `process` inside distribute is what pays the holder share into
  # the coin, so the harvest right after picks up this run's dividends instead of waiting for the next run
  distribute_router "$r" "$pid" "$pad" || rc=1
  harvest_token "$token" || rc=1
  return "$rc"
}

for pad in $(jq -r '.launchpads | keys[]' "$FILE"); do
  factory=$(jq -r --arg p "$pad" '.launchpads[$p].factory // empty' "$FILE")
  if ! [[ "$factory" =~ ^0x[0-9a-fA-F]{40}$ ]] || [ "$factory" = "$ZERO" ]; then
    continue
  fi
  n=$(cast to-dec "$(call "$factory" "allLodestarsLength()")")
  echo "== $pad: $n routers (factory $factory)"
  for i in $(seq 0 $((n - 1))); do
    router=$(call "$factory" "allLodestars(uint256)(address)" "$i")
    echo "-- $pad router $i: $router"
    if ! run_router "$router" "$pad"; then
      echo "::error::$pad router $router failed"
      FAILED=1
    fi
  done
done

exit "$FAILED"
