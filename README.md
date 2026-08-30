# Tensegrity (TNSG)

**Prelaunch reserve / reward protocol on Robinhood Chain**  
**New-chain activity. Old-chain rewards.**

Tensegrity is an independent prelaunch protocol built around TNSG on Robinhood Chain. Its design links activity in the intended official TNSG/USDG market with reserve and reward accounting for BTC, LTC, and DOGE — assets whose native networks use proof-of-work consensus.

**Tensegrity itself does not use proof-of-work consensus, and TNSG is not a proof-of-work-mined token.** The proof-of-work relationship is to the underlying reserve / reward assets.

> **Prelaunch status:** TNSG is deployed, but the official TNSG/USDG market is **not live**. No public protocol market, reserve acquisition, or holder reward distribution should be treated as active until the remaining launch gates are complete.

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

The TNSG token itself is intentionally simple. Protocol economics are intended to live in the official market and surrounding protocol contracts rather than in a wallet-transfer tax.

## Intended market economics

The intended first official market is **TNSG/USDG** on Uniswap v4.

Current prelaunch economic targets are:

- **3.00% holder reserve / reward component**
- **0.25% development reserve component**
- **0.25% LP fee**

These parameters remain subject to final launch validation and activation review.

## Underlying reserve basket

The reserve design is defined in terms of the **underlying economic assets**, not a single wrapped-token issuer:

| Underlying asset | Target allocation |
| --- | ---: |
| BTC | 50% |
| LTC | 25% |
| DOGE | 25% |

A wrapped or bridged token is treated as a **representation of the underlying asset**, not as the holder's economic entitlement itself.

The architecture is being generalized so approved backing can, where appropriate, span multiple independent representations, execution chains, liquidity venues, bridge routes, and eventual native-chain reserve or redemption paths. The objective is fault-domain diversification rather than dependence on a single wrapper, issuer, custodian, or chain.

No specific representation should be treated as permanently approved merely because it appears in an earlier public checkpoint. Representation approval, concentration limits, redemption requirements, and proof-of-backing standards remain subject to security and launch review.

## Holder reward model

The holder reward layer remains under development. Its public design objectives are:

- deterministic and reproducible eligibility accounting;
- auditable reserve backing and liabilities;
- bounded and reproducible allocation logic;
- permissionless execution where practical;
- no representation that rewards are active before activation;
- clear separation between underlying BTC/LTC/DOGE entitlement and the particular approved representation backing that entitlement.

Detailed prelaunch mechanics that are still under security review are intentionally not published here as a complete implementation plan.

## Security and transparency posture

Tensegrity is being developed around narrow authority boundaries, immutable or tightly constrained dependencies where practical, deterministic accounting, and content-addressed validation artifacts.

Current engineering work includes exact-source regression testing, warning disposition, authority-boundary review, external-call and token-movement review, replay/provenance analysis, and cross-chain accounting verification.

This repository is **prelaunch and not a substitute for an independent security review**. Passing internal tests or review gates does not establish that the protocol is risk-free.

## Public repository policy

This public repository is a **selectively published engineering checkpoint**, not necessarily the complete or latest internal working tree.

To reduce operational and security exposure before launch, public commits should not include:

- private keys, seed phrases, signing material, or wallet recovery data;
- API keys, RPC credentials, access tokens, passwords, or private endpoints;
- unreleased deployment secrets or operational credentials;
- private infrastructure configuration;
- security-sensitive runbooks or exploit-relevant operational procedures;
- detailed future architecture or launch sequencing that has not been approved for public release;
- unpublished treasury, liquidity, routing, or execution plans beyond what is necessary for public transparency.

Public source snapshots may intentionally lag current private development while security review is in progress. Older commits may also describe superseded architecture and should not be interpreted as the current production design.

## Current public status

- TNSG is deployed on Robinhood Chain.
- The official TNSG/USDG protocol market is **not live**.
- Holder reserve / reward distribution is **not active**.
- The reserve architecture is being generalized around underlying BTC/LTC/DOGE entitlements and approved representation diversity.
- Security, provenance, reward-accounting, deployment, and activation work remains in progress.

## Publication before launch

Before public activation, the project intends to publish the material needed for users to understand the live system, including the final relevant contracts, addresses, economic parameters, reserve representation policy, transparency methodology, risks, and activation status.

Information that would create avoidable operational or security exposure may remain private until it is safe and necessary to disclose.

## Disclaimer

Tensegrity is under active development. Nothing in this repository is a guarantee of investment return, asset appreciation, reward amount, protocol availability, or regulatory treatment. Protocol parameters, implementation details, deployment topology, and activation sequencing may change before launch where security, operational, or compliance requirements demand it.
