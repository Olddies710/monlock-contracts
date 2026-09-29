#!/usr/bin/env bash
# Source verification of a deployment recorded in deployments/<chainId>.json, on MonadVision (Sourcify) and, when
# ETHERSCAN_API_KEY is set, on Monadscan (Etherscan API v2). Constructor arguments come from the record.
#
#   ./script/verify.sh 10143                     # TokenFactory + LiquidityMigrator + StockReserve implementation
#   ./script/verify.sh 10143 <token>             # a launched LaunchToken and its BondingCurveManager
#   DRY_RUN=1 ./script/verify.sh 10143           # print the commands only
#
# Needs an RPC for the chain only in token mode (to read factory.curveOf): MONAD_RPC_URL / MONAD_TESTNET_RPC_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

CHAIN="${1:?usage: verify.sh <chainId> [token]}"
TOKEN="${2:-}"
RECORD="deployments/${CHAIN}.json"
SOURCIFY_URL="https://sourcify-api-monad.blockvision.org/"
[[ -f "$RECORD" ]] || { echo "no record at $RECORD" >&2; exit 1; }
for tool in forge cast jq; do
  command -v "$tool" >/dev/null || { echo "$tool not found" >&2; exit 1; }
done

field() { jq -r ".$1" "$RECORD"; }

run() {
  echo "+ $*"
  [[ -n "${DRY_RUN:-}" ]] || "$@"
}

# verify <address> <path:Contract> [constructor args as ABI-encoded hex]
verify() {
  local address="$1" contract="$2" args="${3:-}"
  local extra=()
  [[ -n "$args" ]] && extra=(--constructor-args "$args")
  run forge verify-contract "$address" "$contract" --chain "$CHAIN" "${extra[@]}" \
    --verifier sourcify --verifier-url "$SOURCIFY_URL"
  if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
    run forge verify-contract "$address" "$contract" --chain "$CHAIN" "${extra[@]}" \
      --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" --watch
  fi
}

# Plain assignments: a failing substitution aborts here (set -e), instead of verifying with empty arguments.
if [[ -z "$TOKEN" ]]; then
  FACTORY_ARGS="$(cast abi-encode 'constructor(address,address)' "$(field deployer)" "$(field initialTreasury)")"
  MIGRATOR_ARGS="$(cast abi-encode 'constructor(address,address,uint24,int24)' \
    "$(field poolManager)" "$(field factory)" "$(field lpFee)" "$(field tickSpacing)")"
  verify "$(field factory)" src/TokenFactory.sol:TokenFactory "$FACTORY_ARGS"
  verify "$(field migrator)" src/LiquidityMigrator.sol:LiquidityMigrator "$MIGRATOR_ARGS"
  # Created by the factory's constructor with CREATE (nonce 1); stock reserves are ERC-1167 clones of it.
  STOCK_RESERVE_IMPL="$(cast compute-address "$(field factory)" --nonce 1 | awk '{print $NF}')"
  verify "$STOCK_RESERVE_IMPL" src/StockReserve.sol:StockReserve
else
  case "$CHAIN" in
    143) RPC="${MONAD_RPC_URL:?set MONAD_RPC_URL}" ;;
    10143) RPC="${MONAD_TESTNET_RPC_URL:?set MONAD_TESTNET_RPC_URL}" ;;
    *) RPC="${RPC_URL:?set RPC_URL}" ;;
  esac
  CURVE="$(cast call "$(field factory)" 'curveOf(address)(address)' "$TOKEN" --rpc-url "$RPC")"
  [[ "$CURVE" != 0x0000000000000000000000000000000000000000 ]] || { echo "$TOKEN is not from this factory" >&2; exit 1; }
  # Constant init code (parameters come from the factory through transient storage): no constructor arguments.
  verify "$TOKEN" src/LaunchToken.sol:LaunchToken
  verify "$CURVE" src/BondingCurveManager.sol:BondingCurveManager
fi
