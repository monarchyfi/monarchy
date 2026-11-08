#!/usr/bin/env bash
# Dress rehearsal of the Eleos, Kleos, Boxa and ElysPump rollout on a local anvil fork of Elysium mainnet. Sends nothing to
# the real chain: anvil forks it into a local node and every transaction goes there.
#
#   ELYSIUM_RPC_URL=https://rpc.eleos.fun [FORK_BLOCK=358639] tools/rehearse-launchpads.sh
#
# 1. DeployLaunchpads with anvil's first key, an anvil EOA standing in for the multisig (ALLOW_EOA_OWNER=true).
# 2. Twelve hours later FinishLaunchpads, and the stand-in multisig accepts Exile.
# 3. One coin per launchpad, each with a holder share so the harvest runs: TST2255 (Eleos), BULL (Kleos hook A),
#    CHUD (Boxa pairs hook), MIX (ElysPump v2 hook). Each coin's creator role is moved (impersonated) to an anvil
#    key, which then runs ActivateLaunchpad as the creator would. The Kleos router gets the V4Swapper (SWAPPER=v4,
#    phase 2); the others keep the buyback share in reserve (phase 1).
# 4. A locker buys and locks each coin in Exile, traders make volume, and tools/keeper-launchpads.sh runs.
# 5. Checks that every router routed fees, that the Kleos router bought back and burned and the others kept the
#    buyback share, that Exile harvested dividends on all four, and that a second keeper run right after leaves
#    the phase 1 routers alone and doesn't buy back again.
# The deployments file goes to deployments/launchpads/rehearsal.json (git-ignored) and the anvil log to
# $TMPDIR. Needs forge, cast, anvil and jq. KEEP_ANVIL=1 leaves the node running at the end, and
# STOP_BEFORE_KEEPER=1 (with it) stops before step 5, for poking around with cast.
set -euo pipefail

: "${ELYSIUM_RPC_URL:?set ELYSIUM_RPC_URL, for example https://rpc.eleos.fun}"
FORK_BLOCK=${FORK_BLOCK:-358639}
PORT=${PORT:-8547}
RPC=http://127.0.0.1:$PORT
export LAUNCHPADS_FILE=deployments/launchpads/rehearsal.json
FILE=$LAUNCHPADS_FILE
LOG=${TMPDIR:-/tmp}/rehearse-launchpads-anvil.log
DEAD=0x000000000000000000000000000000000000dEaD

# anvil's well-known test keys
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
CREATOR_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
LOCKER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
TRADER_KEY=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
KEEPER_KEY=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
addr() { cast wallet address --private-key "$1"; }
OWNER=$(addr $OWNER_KEY)
CREATOR=$(addr $CREATOR_KEY)
LOCKER=$(addr $LOCKER_KEY)
TREASURY=0x000000000000000000000000000000000000bEEF

TST2255=0x1EaDE08E6BEf1ac50bac8A70e230A26286be3a85
BULL=0xF3bC1443b3aC94FcD77A9808Cc51EbE6007f38bd
CHUD=0xee522C896A72dbE25Ca02d6a56C9E0E41D9FD27E
MIX=0x949a66AC7d58eC0a64B1414A9471F1083143FdAB

anvil --fork-url "$ELYSIUM_RPC_URL" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent >"$LOG" 2>&1 &
ANVIL=$!
if [ "${KEEP_ANVIL:-}" != "1" ]; then trap 'kill $ANVIL 2>/dev/null || true' EXIT; fi
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break || sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC")" = "99901" ] || { echo "the fork is not Elysium mainnet"; exit 1; }
rm -f "$FILE"

# Elysium is an Arbitrum Orbit chain; anvil has no ArbSys precompile, which Kleos's hooks ask about their caller
ARBSYS=$(forge inspect contracts/src/mocks/MockArbSys.sol:MockArbSys deployedBytecode)
cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 \
  "$ARBSYS" --rpc-url "$RPC" >/dev/null

# a fixed, generous gas limit and a receipt check: a send at exactly cast's estimate can run out of gas when the
# block lands in a later Exile hour bucket than the estimate saw, and `cast send` exits 0 on a revert
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

echo "== 1. DeployLaunchpads"
PRIVATE_KEY=$DEPLOYER_KEY FACTORY_OWNER=$OWNER ALLOW_EOA_OWNER=true script DeployLaunchpads.s.sol
EXILE=$(jq -r .exile "$FILE")
OBSERVER=$(jq -r .observer "$FILE")

echo "== 2. FinishLaunchpads, 12 hours later"
warp 43201
PRIVATE_KEY=$KEEPER_KEY script FinishLaunchpads.s.sol
send "$EXILE" "acceptOwner()" --private-key "$OWNER_KEY"
[ "$(call "$EXILE" "owner()(address)")" = "$OWNER" ] || { echo "Exile owner not handed over"; exit 1; }

# move a coin's creator role to the rehearsal creator key, impersonating the real creator
take_role() {
  local pad=$1 coin=$2 src hook id real
  src=$(jq -r --arg p "$pad" '.launchpads[$p].source' "$FILE")
  hook=$(call "$src" "hookOf(address)(address,(uint8,address))" "$coin" | sed -n 1p)
  id=$(call "$(jq -r --arg p "$pad" '.launchpads[$p].factory' "$FILE")" "predict(address,address)(address,bytes32)" \
    "$coin" 0x0000000000000000000000000000000000000000 | sed -n 2p)
  real=$(call "$src" "creator(address,bytes32)(address)" "$coin" "$id")
  cast rpc anvil_impersonateAccount "$real" --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setBalance "$real" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
  if [ "$pad" = "boxa" ]; then
    send "$hook" "proposeCreator(bytes32,address)" "$id" "$CREATOR" --unlocked --from "$real"
    send "$hook" "acceptCreator(bytes32)" "$id" --private-key "$CREATOR_KEY"
  elif [ "$pad" = "elyspump" ]; then
    send "$hook" "setFeeReceiver(address,address)" "$coin" "$CREATOR" --unlocked --from "$real"
  else
    send "$hook" "transferCreator(address,address)" "$coin" "$CREATOR" --unlocked --from "$real"
  fi
  [ "$(call "$src" "creator(address,bytes32)(address)" "$coin" "$id")" = "$CREATOR" ] || {
    echo "role not moved for $coin"
    exit 1
  }
}

# buy <pad> <coin> <wei> <to> <key>: a real buy through the coin's pool via the deployment's V4Swapper
buy() {
  local pad=$1 coin=$2 amount=$3 to=$4 key=$5 src info pm keyTuple id swapper
  src=$(jq -r --arg p "$pad" '.launchpads[$p].source' "$FILE")
  info=$(call "$src" "hookOf(address)(address,(uint8,address))" "$coin" | sed -n 2p)
  pm=$(grep -oE '0x[0-9a-fA-F]{40}' <<<"$info")
  keyTuple=$(call "$src" "poolKey(address)((address,address,uint24,int24,address))" "$coin" | tr -d ' ')
  id=$(cast keccak "$(cast abi-encode "f((address,address,uint24,int24,address))" "$keyTuple")")
  swapper=$(jq -r --arg p "$pad" --arg pm "$pm" \
    '.launchpads[$p] as $l | [range(0; $l.poolManagers | length) | select(($l.poolManagers[.] | ascii_downcase) == ($pm | ascii_downcase)) | $l.swappers[.]][0]' "$FILE")
  send "$OBSERVER" "poke(address,(address,address,uint24,int24,address))" "$pm" "$keyTuple" --private-key "$key"
  send "$swapper" "buyExactIn(bytes32,uint256,uint256,address)" "$id" "$amount" 0 "$to" --value "$amount" \
    --private-key "$key"
}

ROUTERS=()
# the Kleos router buys back through the deployment's V4Swapper (phase 2); the others keep the buyback share in
# reserve (phase 1)
for spec in "eleos $TST2255 none" "kleos $BULL v4" "boxa $CHUD none" "elyspump $MIX none"; do
  read -r pad coin swap <<<"$spec"
  echo "== 3. $pad: activate $coin"
  take_role "$pad" "$coin"
  if [ "$swap" = "v4" ]; then export SWAPPER=v4; else unset SWAPPER; fi
  PRIVATE_KEY=$CREATOR_KEY LAUNCHPAD=$pad TOKEN=$coin TREASURY=$TREASURY script ActivateLaunchpad.s.sol
  unset SWAPPER
  factory=$(jq -r --arg p "$pad" '.launchpads[$p].factory' "$FILE")
  router=$(call "$factory" "lodestarOf(address)(address)" "$coin")
  [ "$(call "$router" "isCreator()(bool)")" = "true" ] || { echo "$pad router does not hold the role"; exit 1; }
  ROUTERS+=("$pad $coin $router $swap")

  echo "== 4. $pad: a locker locks, traders trade"
  buy "$pad" "$coin" 300000000000000000 "$LOCKER" "$LOCKER_KEY"
  warp 1200
  bal=$(call "$coin" "balanceOf(address)(uint256)" "$LOCKER" | num)
  pid=$(cast to-dec "$(call "$router" "exilePoolId()")")
  send "$coin" "approve(address,uint256)" "$EXILE" "$bal" --private-key "$LOCKER_KEY"
  unlock=$(($(cast block latest -f timestamp --rpc-url "$RPC") + 30 * 86400))
  send "$EXILE" "lockERC20(address,uint256,uint64,uint256)" "$coin" "$bal" "$unlock" "$pid" --private-key "$LOCKER_KEY"
done

# volume on all four coins, spread out so Eleos's hook sees a market and not one jump. Twenty rounds so that
# CHUD, whose creator gets the least of the tax, clears the keeper's 0.001 HYPE minimum
for _ in $(seq 1 20); do
  for r in "${ROUTERS[@]}"; do
    read -r pad coin _ _ <<<"$r"
    buy "$pad" "$coin" 200000000000000000 "$DEAD" "$TRADER_KEY"
  done
  warp 120
done
warp 1200

if [ "${STOP_BEFORE_KEEPER:-}" = "1" ]; then
  echo "stopping before the keeper; anvil (pid $ANVIL) serves $RPC"
  exit 0
fi

echo "== 5. keeper"
RPC_URL=$RPC KEEPER_PRIVATE_KEY=$KEEPER_KEY tools/keeper-launchpads.sh "$FILE" 99901

# right after, the phase 1 routers have nothing to route. The phase 2 router may route the creator fee its own
# buyback just paid on Kleos's tax, but must not buy again inside the 30 minute buyback interval.
read -r _ _ KLEOS_ROUTER _ <<<"${ROUTERS[1]}"
burnedBefore=$(call "$KLEOS_ROUTER" "totalBuybackTokensBurned()(uint256)" | num)
echo "== 5b. keeper again, right after"
second=$(RPC_URL=$RPC KEEPER_PRIVATE_KEY=$KEEPER_KEY tools/keeper-launchpads.sh "$FILE" 99901)
echo "$second"
if [ "$(grep -c "^distribute()" <<<"$second" || true)" -gt 1 ] || grep -q "^harvest brings" <<<"$second"; then
  echo "the second keeper run did more than route the buyback's own fee"
  exit 1
fi
[ "$(call "$KLEOS_ROUTER" "totalBuybackTokensBurned()(uint256)" | num)" = "$burnedBefore" ] || {
  echo "bought back twice inside the buyback interval"
  exit 1
}

echo "== checks"
ok=1
for r in "${ROUTERS[@]}"; do
  read -r pad coin router swap <<<"$r"
  holders=$(call "$router" "totalHoldersQuote()(uint256)" | num)
  treasury=$(call "$router" "totalTreasuryQuote()(uint256)" | num)
  reserve=$(call "$router" "buybackReserve()(uint256)" | num)
  burned=$(call "$router" "totalBuybackTokensBurned()(uint256)" | num)
  echo "$pad $coin router $router: lockers $holders, treasury $treasury, buyback reserve $reserve (wei)," \
    "bought back and burned $burned coins"
  if [ "$holders" = "0" ] || [ "$treasury" = "0" ]; then ok=0; fi
  # phase 1 keeps the buyback share; phase 2 spends it on the coin and burns what it buys
  if [ "$swap" = "v4" ] && [ "$burned" = "0" ]; then ok=0; fi
  if [ "$swap" != "v4" ] && [ "$reserve" = "0" ]; then ok=0; fi
done
harvested=$(cast logs --from-block "$FORK_BLOCK" --address "$EXILE" "Harvested(address indexed,uint256 indexed,uint256,bool)" \
  --rpc-url "$RPC" --json | jq length)
echo "Exile harvests: $harvested"
[ "$harvested" -ge 4 ] || ok=0
rm -f "$FILE"
if [ "$ok" = 1 ]; then echo "rehearsal passed"; else echo "rehearsal FAILED"; exit 1; fi
