#!/usr/bin/env bash
# Full broadcast rehearsal of DEPLOYMENT.md on a local anvil node that forks Monad testnet with Monad's execution
# rules (`--network monad`): deploy, audit, Safe handoff, idempotent re-run and the smoke lifecycle, with real
# blocks and receipts. Ends with the gas used and gas limit of every transaction.
#
#   MONAD_TESTNET_RPC_URL=https://testnet-rpc.monad.xyz ./script/rehearse.sh
#
# The node runs with chain id 31337, so nothing is ever recorded as a testnet deployment (deployments/31337.json and
# broadcast/*/31337/ are gitignored). Accounts are fresh and impersonated: anvil's default keys are public, and on
# public testnets those accounts are EIP-7702-delegated to contracts that can move whatever they receive.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${MONAD_TESTNET_RPC_URL:?set MONAD_TESTNET_RPC_URL}"
PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
GAS_MULTIPLIER="${GAS_MULTIPLIER:-110}" # Monad bills the gas limit: keep forge's headroom small (default is 130)
TESTNET_POOL_MANAGER=0x451D64ab3b650040d2aE1886602b97ed6eDc643d

step() { printf '\n==> %s\n' "$*"; }

anvil --fork-url "$MONAD_TESTNET_RPC_URL" --network monad --chain-id 31337 --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.5; done
cast chain-id --rpc-url "$RPC" >/dev/null

account() { cast wallet address --private-key "$(cast keccak "launchpad.rehearsal.$1")"; }
DEPLOYER="$(account deployer)"
TREASURY="$(account treasury)"
SAFE="$(account safe)"
for a in "$DEPLOYER" "$SAFE"; do
  cast rpc anvil_impersonateAccount "$a" --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setBalance "$a" 0x3635c9adc5dea00000 --rpc-url "$RPC" >/dev/null # 1,000 MON
done
cast rpc anvil_setCode "$SAFE" 0x00 --rpc-url "$RPC" >/dev/null # stands in for a Safe (a contract)
mine() { cast rpc anvil_mine "$(printf '0x%x' "$1")" --rpc-url "$RPC" >/dev/null; }

export POOL_MANAGER="$TESTNET_POOL_MANAGER" PROTOCOL_TREASURY="$TREASURY" FINAL_OWNER="$SAFE"
BROADCAST=(--rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEPLOYER" --gas-estimate-multiplier "$GAS_MULTIPLIER")

step "Deploy (simulation, then phase 1: contracts, phase 2: configuration)"
# Two phases as on a live network (DEPLOYMENT.md §5.2). anvil does not enforce the gas limit of the mis-estimated
# calls, so a single run would pass here and still fail on Monad.
forge script script/Deploy.s.sol --rpc-url "$RPC" --sender "$DEPLOYER" >/dev/null
CONTRACTS_ONLY=true forge script script/Deploy.s.sol "${BROADCAST[@]}" | grep -E 'CONTRACTS_ONLY'
forge script script/Deploy.s.sol "${BROADCAST[@]}" | grep -E '^  (==|  [A-Za-z])|next:'

step "CheckDeployment (handoff pending: 1 warning)"
forge script script/CheckDeployment.s.sol --rpc-url "$RPC" | grep -E '\[(FAIL|WARN)\]|failures'

FACTORY="$(jq -r .factory deployments/31337.json)"
step "Safe accepts ownership"
cast send "$FACTORY" "acceptOwnership()" --unlocked --from "$SAFE" --rpc-url "$RPC" | grep -E '^status'

step "CheckDeployment (must be clean)"
forge script script/CheckDeployment.s.sol --rpc-url "$RPC" | grep -E '\[(FAIL|WARN)\]|failures'

step "Deploy again (idempotent: nothing to send)"
forge script script/Deploy.s.sol "${BROADCAST[@]}" 2>&1 | grep -E 'owned by|No transactions'

step "Smoke lifecycle on preset 2"
forge script script/SmokeLaunch.s.sol --sig "launch()" "${BROADCAST[@]}" | grep -E '^  (token|curve|dev buy)'
TOKEN="$(jq -r .returns.token.value broadcast/SmokeLaunch.s.sol/31337/launch-latest.json)"
mine 1 # a sell in the dev-buy block would hit the same-block round-trip guard
forge script script/SmokeLaunch.s.sol --sig "trade(address)" "$TOKEN" "${BROADCAST[@]}" | grep -E '^  fee now'
mine 200 # anti-snipe window (~60 s of 300 ms blocks on Monad)
forge script script/SmokeLaunch.s.sol --sig "graduate(address)" "$TOKEN" "${BROADCAST[@]}" | grep -E '^  (buying|graduated)'
forge script script/SmokeLaunch.s.sol --sig "claim(address)" "$TOKEN" "${BROADCAST[@]}" | grep -E '^  curve fees'

step "Verification commands (dry run: the node is local)"
DRY_RUN=1 ./script/verify.sh 31337 | sed -E 's/(--constructor-args 0x)[0-9a-f]+/\1…/'
DRY_RUN=1 RPC_URL="$RPC" ./script/verify.sh 31337 "$TOKEN"

step "Gas per transaction (Monad bills the limit)"
printf '%-18s %-26s %12s %12s\n' contract function gasUsed gasLimit
for f in Deploy.s.sol/31337/run SmokeLaunch.s.sol/31337/launch SmokeLaunch.s.sol/31337/trade \
  SmokeLaunch.s.sol/31337/graduate SmokeLaunch.s.sol/31337/claim; do
  jq -r 'def hex: ltrimstr("0x") | explode
      | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 elif $c >= 65 then $c - 55 else $c - 48 end));
    [.transactions, .receipts] | transpose[]
    | [(.[0].contractName // "-"), ((.[0].function // "create2") | split("(")[0]),
       (.[1].gasUsed | hex), (.[0].transaction.gas | hex)] | @tsv' "broadcast/${f}-latest.json"
done | while IFS=$'\t' read -r contract fn used limit; do
  printf '%-18s %-26s %12s %12s\n' "$contract" "$fn" "$used" "$limit"
done
