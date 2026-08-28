# Tensegrity (TNSG)

**Native Proof-of-Work Reserve / Reward Protocol**  
**New-chain activity. Old-chain rewards.**

Tensegrity is a prelaunch protocol built around TNSG on Robinhood Chain. The protocol is designed so activity in the official TNSG/USDG Uniswap v4 market funds purchases of a fixed basket of native proof-of-work assets on Base, with separate holder and development reserve accounting.

> **Prelaunch status:** TNSG is deployed, but the official TNSG/USDG market is **not live**. Public trading, the CCA, the hooked v4 market, production Base deployments, and holder reward distribution remain intentionally inactive until the remaining protocol, deployment, transparency, and activation gates are complete.

## Canonical TNSG

- **Network:** Robinhood Chain mainnet
- **Chain ID:** `4663`
- **Token:** `TNSG`
- **Contract:** `0x6e43d92B4aE9C1093d6EfE42b18375f4B3176DAc`
- **Fixed supply:** `100,000,000 TNSG`
- **Decimals:** `18`
- **Token transfer tax:** `0%`
- **Upgradeability:** none
- **Owner/admin:** none
- **Additional minting:** none
- **Canonical X:** `@TensegrityPoW`

The TNSG token itself is intentionally simple. Protocol economics are implemented through the official market and surrounding protocol contracts rather than a wallet-transfer tax in the ERC-20.

## Protocol economics

The intended official market is **TNSG/USDG** on Uniswap v4.

Configured market economics:

- **3.00% Holder PoW Reward Fee**
- **0.25% Development PoW Reserve Fee**
- **0.25% LP fee**
- **3.50% nominal configured total**

The hook-controlled 3.25% protocol component is split economically as:

- **Holder reserve:** `12/13`
- **Development reserve:** `1/13`

The development fee is designed to acquire the same PoW reserve basket rather than remain in USDG or ETH.

## Proof-of-Work reserve basket

On Base, the acquisition engine is designed for the following fixed basket:

| Asset | Allocation | Canonical Base token |
| --- | ---: | --- |
| cbBTC | 50% | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| cbLTC | 25% | `0xcb17C9Db87B595717C857a08468793f5bAb6445F` |
| cbDOGE | 25% | `0xcbD06E5A2B0C65597161de254AA074E489dEb510` |

Canonical Base USDC:

`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`

## Architecture

Current protocol flow:

```text
Robinhood Chain

TNSG/USDG Uniswap v4 market
        |
        v
TensegrityFeeHook
        |
        v
TensegrityFeeVault
        |
        v
TensegritySettlementExecutor
        |
        v
TensegrityRelayBridgeAdapter
        |
        | Relay settlement
        v
Base

TensegrityBaseReceiver
        |
        v
TensegrityPoWAcquisitionExecutor
        |
        +--> HolderReserveVault       (12/13)
        |
        +--> DevelopmentReserve       (1/13)
```

The current acquisition successor additionally authenticates reserve bindings and records reserve accounting atomically with physical cbBTC/cbLTC/cbDOGE transfers. If reserve accounting fails, the acquisition transaction is designed to revert atomically.

## Holder reward model

The holder reward system is being designed around:

- 7-day epochs
- time-weighted average balance (TWAB) eligibility
- direct PoW asset rewards
- 5% per-address reward cap
- iterative redistribution of cap excess
- rollover when eligible capacity is insufficient
- bounded and resumable reward pushes
- permissionless execution
- no human weekly reward-release authority
- no mutable holder-reward admin

The cross-chain entitlement/finalization layer is still under development. TNSG is a plain ERC-20 on Robinhood Chain while reserve assets are held on Base, so historical holder entitlement commitments require a separate deterministic and trust-minimized verification design before holder rewards can be activated.

## Security posture

The protocol is being developed around immutable dependencies and narrow authority boundaries. Current design goals include:

- no arbitrary acquisition routes
- no generic aggregator calldata
- fixed canonical PoW assets
- oracle-backed minimum output protection
- sequencer checks on Base
- exact finite token approvals with residual allowance checks
- permissionless acquisition execution
- immutable reserve destinations
- authenticated reserve accounting
- no arbitrary HolderReserve withdrawal
- no HolderReserve owner/admin
- DevelopmentReserve releases only to its immutable beneficiary
- direct unsolicited reserve-token transfers treated separately from accounted protocol reserve

This repository is **pre-audit and pre-production-deployment**. Passing tests are not a substitute for an independent security review.

## Current engineering status

Latest locally accepted protocol regression:

- **9 Foundry test suites**
- **99 tests passed**
- **0 failed**
- **0 skipped**

Current accepted reserve/integration artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `TensegrityHolderReserveVault.sol` | `a7e6f4cc9517bb1d307cbd14451e86ce35ac338030ede847ee12c77e8f3250df` |
| `TensegrityHolderReserveVault.t.sol` | `25f2387801af099ca6f80c1813f3155f087511693d013b828335676e3793981d` |
| `TensegrityDevelopmentReserve.sol` | `ea168ba9979f16bd66fdb4cf5a694506f958c3a1b6c84924c328405f18a99173` |
| `TensegrityDevelopmentReserve.t.sol` | `29d935ff91434ee2e7e2d7947d19e6050699bb58468e4c9aab43e9d77c14e1dc` |
| `TensegrityPoWAcquisitionExecutor.sol` successor | `ba89394627a3bf2aeadb124d901fe6f89f1398e5c70b372d9727516ebfd38b5f` |
| `TensegrityPoWAcquisitionExecutor.t.sol` successor | `28e24a036d066682953eee4a084e59b0227f7ab4efc96e28b1525cf65aabfe8b` |

The prior AcquisitionExecutor R1 source hash (`137e3eab...677c4`) remains historical acceptance evidence; the reserve-integration successor above is the current accepted executor candidate.

## Remaining prelaunch work

Major remaining gates include:

1. Publish the exact accepted protocol source and tests to this repository.
2. Complete deterministic TWAB and exclusion accounting.
3. Implement the 5% cap, iterative redistribution, and rollover mechanics.
4. Freeze and verify the cross-chain epoch commitment/finalization model.
5. Implement the permissionless bounded RewardDistributor.
6. Add Proof of Assets / Proof of Liabilities and cross-chain reconciliation surfaces.
7. Freeze deterministic deployment topology and production addresses.
8. Complete warning provenance review, deployment dry-run, and security review.
9. Complete CCA end-to-end testing and activation review.
10. Finalize public documentation, disclosures, whitepaper, and website.
11. Activate the official hooked TNSG/USDG market only after the launch gates are satisfied.

## Website

The project website is planned to be published through GitHub Pages as a low-cost official prelaunch site. Planned sections include:

- How It Works
- Token / Contracts
- PoW Reserve
- Holder Rewards
- Security / Transparency
- Roadmap
- Risks / Disclosures

## Launch policy

The first public TNSG market is intended to be the real protocol market rather than a temporary hookless market. Until activation gates are complete:

- the official TNSG/USDG market is not live;
- no public protocol liquidity is being represented as live;
- no holder PoW rewards are represented as active;
- Base protocol addresses should not be treated as production addresses until the deployment topology is frozen and deployed.

## Disclaimer

Tensegrity is under active development. Nothing in this repository is a guarantee of investment return, asset appreciation, reward amount, protocol availability, or regulatory treatment. Protocol parameters, deployment details, and activation sequencing may change before public launch where security or compliance requires it.
