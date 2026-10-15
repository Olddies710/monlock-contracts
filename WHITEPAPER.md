# MonLock: how it works

*A token launchpad on Monad. Version 1.0, October 2026. Everything here can be checked on-chain or in the public
contracts repository.*

## 1. What MonLock is, and what it is not

MonLock lets anyone launch a token on Monad mainnet and trade it from the first block. Every token starts on a
bonding curve. When the curve has raised its target, the token graduates to a Uniswap v4 pool and the liquidity is
locked by contract.

**MonLock has no token.** There is no MONLOCK coin, no presale, no airdrop and no points-for-token program. We will
never ask you to buy, stake or claim anything to "access" MonLock. The only asset you need is MON, to pay for trades
and gas.

**MonLock is built and run by one person.** There is no company, no team behind the project and no investors.
Support, development, operations and marketing are one person. That means slower answers and no 24/7 coverage. It
also means nobody else holds a key.

**Any token that uses our name is not ours.** Anyone can deploy a token, on any chain, with any name, including
"MonLock". We have not launched one, we do not endorse any token created on the platform, and the site hides tokens
that imitate the brand. If a token claims to be the MonLock coin, it is not.

**Official channels**
- Website: https://monlock.xyz
- X: https://x.com/Monlockxyz
- Telegram (announcements only, no chat): https://t.me/monlockxyz
- Code: https://github.com/Olddies710/monlock-contracts
- Security reports: security@monlock.xyz

The team never DMs first and never asks for private keys or seed phrases. Anyone who does is a scammer.

## 2. How a launch works

1. A creator picks a name, a symbol and an image, and pays only gas. There is no listing fee and no upfront
   liquidity.
2. The factory creates the token and its own curve contract. The token has a **fixed supply of 1,000,000,000**,
   minted once. It has no mint function and no owner.
3. **80 % of the supply (800 M) is sold on the curve. 20 % (200 M) is reserved for the pool** the token graduates to.
4. The creator may make an optional first buy in the same transaction, capped at 5 % of the supply.
5. Anyone can buy and sell against the curve. There is no order book, only the curve price.

Each launch has its own contracts and its own balance: a problem in one token cannot touch another.

## 3. The curve

The price follows a constant-product curve with virtual reserves, the same family of formula Uniswap uses.

| | |
|---|---|
| Starting price | about 0.000164 MON per token |
| Starting market cap | about 164,000 MON |
| MON raised to graduate | **500,000 MON** |
| Market cap at graduation | about 2,375,000 MON |
| Price from start to graduation | about 14.4× |

Buying pushes the price up and selling pushes it down. Every trade needs a minimum-output limit, so a trade that
would execute far from the quoted price reverts instead of filling.

## 4. Launch protection

The first minutes are when bots do the most damage. MonLock handles that on-chain, with rules that do not depend on a
private mempool:

- **Decaying sniper fee.** The total fee starts at 50 % in the launch block and falls quadratically to 1 % over 200
  blocks (about 60 seconds). The part above 1 % is not paid to anyone: it is donated back to the curve, so it benefits
  holders, not the creator or the protocol.
- **Purchase cap.** While the fee is decaying, a single buy cannot exceed 1 % of the total supply.
- **No same-block round trip.** A wallet that buys in a block cannot sell to the curve in that same block, including by
  moving the tokens to a second wallet. This removes the classic sandwich on buyers.
- **Only MonLock can create the pool.** Nobody can create the token's Uniswap pool at a manipulated price before
  graduation.

These rules reduce sniping, they do not make it impossible. A bot that accepts the fee can still buy, and the fee it
pays goes to the curve.

## 5. Graduation and locked liquidity

When the curve has raised its target, the transaction that fills it also graduates the token:

- A **5 % graduation fee** is taken on the MON raised (25,000 MON at the standard target): 30 % to the creator, 70 % to
  the protocol.
- The rest, **475,000 MON plus the 200 M reserved tokens**, becomes full-range liquidity in a Uniswap v4 pool.
- **The liquidity is locked in a contract with no withdrawal function.** Nobody, including the creator, the owner and
  us, can remove it. Only the swap fees that liquidity earns can be collected.
- If the migration fails for any reason, the curve stays in a "completed" state and anyone can retry graduation.

## 6. Fees

| Where | Fee | Split |
|---|---|---|
| Curve trades (buy and sell) | 1 % | 30 % creator, 60 % protocol, 10 % referrer |
| Graduation | 5 % of the MON raised | 30 % creator, 70 % protocol |
| Trades in the pool after graduation | 1 % | 70 % creator, 30 % protocol |

The referrer is whoever integrated the trade (an app or a bot). Without one, its share goes to the protocol. All
rates and splits are copied into each launch **when it is created** and cannot be changed afterwards, not even by the
owner.

## 7. Who can change what

The protocol owner is a **2-of-3 multisignature wallet (Safe)**:
`0x360c402C747F6fa7878B04b115307D4dE8DF3BC7`.

**It can**
- pause the creation of new launches,
- set the parameters of future launches,
- change the protocol's treasury address,
- manage the list of allowed stock tokens for the optional stock-reserve feature, which is not in use today.

**It cannot**
- touch the MON held in any curve,
- touch locked liquidity,
- touch any token or any holder's balance,
- change the fees, supply or rules of a launch that already exists,
- mint tokens or stop trading on an existing curve.

The contracts are permissionless: if the website were offline, anyone could still trade directly against them.

## 8. Adding MON from other chains, and signing in

Both features are optional conveniences. Neither can access your funds.

- **Add MON from 15 chains** uses Aurora Intents. You choose a chain and an asset, send it to a one-time deposit
  address that Aurora gives you, and Aurora delivers native MON to your own wallet on Monad. MonLock has no contract in
  that flow and never holds the funds. If a swap cannot complete, Aurora refunds to the address you provided on the
  source chain.
- **Sign in with email, Google, Apple, X or Discord** uses Reown's embedded wallets, or you can connect MetaMask,
  Trust Wallet or any WalletConnect wallet. With an embedded wallet, the keys are managed by Reown, not by MonLock.
  Export or back them up as you would with any wallet.

## 9. Known limits and risks

- **No external audit yet.** The contracts have been internally reviewed and are covered by unit, fuzz, invariant and
  fork tests against the real Uniswap v4 deployment on Monad. A professional audit is planned before volume grows.
  Until then, treat the contracts as unaudited software.
- **One person.** A bug, a lost key or an illness has a single point of failure. The multisig reduces the key risk, but
  it is operated by the same person.
- **Tokens are speculative.** Most tokens on a bonding curve lose value, and some go to zero. MonLock does not vet,
  rate or recommend any token. Creators control their token's name, image and links, which can be misleading.
- **Locked liquidity does not mean a safe token.** It means the pool cannot be withdrawn. The price can still fall.
- **Third-party dependencies.** Uniswap v4, Monad itself, Aurora and Reown can have problems of their own.
- **Not financial advice.** Nothing here is an offer or a recommendation. Check your local rules before using the
  service.

## 10. Verify it yourself

| What | Address (Monad mainnet, chain 143) |
|---|---|
| Factory | `0x3Ec6905A80A8E981159fF7EA1Ee48C60eD737920` |
| Liquidity migrator (locks liquidity, Uniswap v4 hook) | `0x5efaAe7CF64A22b62672eAb5A87A6fAe166AE000` |
| Owner (Safe 2-of-3) | `0x360c402C747F6fa7878B04b115307D4dE8DF3BC7` |

Contract source and tests: https://github.com/Olddies710/monlock-contracts. To report a vulnerability, write to
security@monlock.xyz and do not open a public issue.

*MonLock is a tool, not a promise. Do your own research and never invest more than you can afford to lose.*
