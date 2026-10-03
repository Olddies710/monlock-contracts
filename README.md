# MonLock contracts

Smart contracts of [MonLock](https://monlock.xyz), a token launchpad on Monad. Anyone can launch a token in one
transaction. It trades on a bonding curve until it sells out, then its liquidity moves to Uniswap v4 and stays locked
forever: no owner and no function can remove it.

- **Live on Monad mainnet** since block 109,741,113 (1 Oct 2026): [monlock.xyz](https://monlock.xyz)
- **X:** [@Monlockxyz](https://x.com/Monlockxyz) · **Contact:** support@monlock.xyz

The history of this repository is the history of the contracts, from the first commit (29 Sep 2026) to the mainnet
deployment (1 Oct 2026). It was split out of MonLock's main repository, which also holds the web app, indexer and
API. Access to that repository can be given to reviewers on request.

## Deployments

### Monad mainnet (chain 143)

| Contract | Address | Source |
|---|---|---|
| TokenFactory | `0x3Ec6905A80A8E981159fF7EA1Ee48C60eD737920` | [MonadVision](https://monadvision.com/address/0x3Ec6905A80A8E981159fF7EA1Ee48C60eD737920) · [Monadscan](https://monadscan.com/address/0x3Ec6905A80A8E981159fF7EA1Ee48C60eD737920#code) |
| LiquidityMigrator (Uniswap v4 hook) | `0x5efaAe7CF64A22b62672eAb5A87A6fAe166AE000` | [MonadVision](https://monadvision.com/address/0x5efaAe7CF64A22b62672eAb5A87A6fAe166AE000) · [Monadscan](https://monadscan.com/address/0x5efaAe7CF64A22b62672eAb5A87A6fAe166AE000#code) |
| StockReserve implementation | `0x5E51d293Bf80eb32AA62C18fa8F0D8ab9E6D2c75` | [MonadVision](https://monadvision.com/address/0x5E51d293Bf80eb32AA62C18fa8F0D8ab9E6D2c75) · [Monadscan](https://monadscan.com/address/0x5E51d293Bf80eb32AA62C18fa8F0D8ab9E6D2c75#code) |
| Owner and treasury (Safe, 2 of 3) | `0x360c402C747F6fa7878B04b115307D4dE8DF3BC7` | |

The full record, including salts and init code hashes, is in [`deployments/143.json`](deployments/143.json).

### Monad testnet (chain 10143)

The same contracts, plus a smoke preset that graduates at 1 MON so the whole lifecycle runs on a faucet budget. The
record is in [`deployments/10143.json`](deployments/10143.json). The receipts of a full launch, trade, graduation and
fee claim are under [`broadcast/SmokeLaunch.s.sol/10143`](broadcast/SmokeLaunch.s.sol/10143).

## How a launch works

1. **Launch.** `TokenFactory` creates the token and its curve in one transaction. The token has a fixed supply of
   1,000,000,000, minted once: it has no owner, no mint, no blacklist, no pause and no transfer tax. 800M go to the
   curve and 200M are kept for the pool. There is no launch fee, only gas. The creator receives no tokens unless they
   buy them at launch (at most 5 % of supply).
2. **Bonding curve.** `BondingCurveManager` sells and buys the token against native MON on a constant-product curve
   with virtual reserves. It charges a 1 % fee on every trade: 30 % to the creator, 60 % to the protocol and 10 % to a
   referrer.
3. **Anti-snipe.** For the first 200 blocks the fee starts at 50 % and decays to 1 %, and a single buy is capped at
   1 % of supply. Selling to the curve in the same block you bought from it reverts, which stops sandwiches.
4. **Graduation.** When the curve has raised 500,000 MON, at a 2.375M MON market cap, it graduates in the same
   transaction as the buy that sold it out. If that migration fails, for example because the buy ran short of gas,
   the buy still goes through and anyone can finish the migration later with `graduate()`. A 5 % graduation fee is
   taken, of which the creator gets 7,500 MON. Then 475,000 MON and the 200M reserved tokens are added as full-range
   liquidity to a Uniswap v4 pool.
5. **Locked liquidity.** `LiquidityMigrator` owns the pool's position and has no owner and no function to withdraw it.
   It is also the pool's hook, with only `beforeInitialize` enabled (address flags `0x2000`), so only it can create
   pools with itself. Swaps go straight through Uniswap v4: no dynamic fee and no custom swap logic. The pool's 1 % LP
   fee is collected for the creator (70 %) and the protocol (30 %).

`StockReserve` is optional: a launch gets one only if the owner has allowlisted a stock token and the creator picks
it. It receives 5 % of the curve fees, taken from the protocol's share, and a keeper converts them into that stock
through a Uniswap v4 pool. It has no withdrawal path.

## What the owner can and cannot do

The owner is a 2-of-3 Safe.

- **It can:** pause new launches, set the presets and parameters of future launches, set the treasury and manage the
  stock allowlist.
- **It cannot:** touch the MON held by a curve, the locked liquidity, anyone's tokens, or the terms of a launch that
  already exists.

Each launch stores its own parameters when it is created.

## Code

| File | What it does |
|---|---|
| `src/TokenFactory.sol` | Launches (also with EIP-712 signed launches), presets, pause, treasury, stock allowlist |
| `src/LaunchToken.sol` | The fixed-supply ERC-20 |
| `src/BondingCurveManager.sol` | The curve: buy, sell, anti-snipe, fees, graduation |
| `src/LiquidityMigrator.sol` | Uniswap v4 hook that creates the pool, adds and holds the liquidity, and collects LP fees |
| `src/StockReserve.sol` | Optional per-launch stock reserve (ERC-1167 clone with immutable arguments) |
| `src/libraries/BondingCurveMath.sol` | Curve math, rounding always in the curve's favour |
| `script/Deploy.s.sol` | Deployment in two phases (create, then configure) with CREATE2 salts and the hook address mined |
| `script/CheckDeployment.s.sol` | Checks a live deployment against this build: code, owners, presets and wiring |
| `script/verify.sh` | Source verification on MonadVision (Sourcify) and Monadscan |

## Build and test

Needs [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recurse-submodules https://github.com/Olddies710/monlock-contracts
cd monlock-contracts
forge build
forge test                                   # 145 unit, fuzz and invariant tests; the fork tests skip
MONAD_RPC_URL=https://rpc.monad.xyz forge test --match-path 'test/fork/*'
```

The fork tests run against Monad's live Uniswap v4: deployment, graduation into the real PoolManager, buying and
selling through the Universal Router, and gas profiles.

To check that the deployed contracts are this code:

```sh
forge script script/CheckDeployment.s.sol --rpc-url https://rpc.monad.xyz
```

The contracts compile with `bytecode_hash = "none"` and without CBOR metadata, so Sourcify reports a "match" (the
runtime bytecode matches) rather than an "exact match" (which also compares the metadata hash).

## Security

There has been no external audit yet. Every core contract went through an internal review, with no finding that could
lose funds. The tests also fuzz the curve's invariants and run the full lifecycle on forks of mainnet and testnet.

Please report vulnerabilities privately to **security@monlock.xyz**, not in public issues. We reply within 72 hours.

## License

Each file's SPDX header gives its license:

- **Core contracts:** `TokenFactory`, `LaunchToken`, `BondingCurveManager`, `LiquidityMigrator` and `StockReserve` are
  under the Business Source License 1.1.
- **Everything else:** interfaces, types and libraries are under MIT.

The BUSL parameters (Licensor, Change Date, Change License) are not set yet. Until a `LICENSE` file sets them, the core
contracts are published here for reading and verification only.
