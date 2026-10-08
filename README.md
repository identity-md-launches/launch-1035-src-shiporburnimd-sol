# Ship or Burn contracts

Vesting by shipping, verified by the IMD swarm. One contract holds every vault. Each IMD oracle attestation of a repo's merged pull request count releases one tranche to the builder when the count rose, or sends it to `0x…dEaD` (or back to the funder, for refund vaults) when it stayed flat. Whatever is left at the deadline goes the same way.

No owner, no admin, no upgrade. Anyone can settle.

## Setup

```sh
forge test
```

Built with Foundry 1.8.3, the version IMD's verifier runs, and solc 0.8.26. Dependencies are vendored under `lib/` (see `lib/DEPENDENCIES.md`), so no install step is needed.

## Contracts

| File | What it is |
| --- | --- |
| `src/ShipOrBurn.sol` | Vaults, the six checks, `settle`, `expire` |
| `src/ShipOrBurnIMD.sol` | The launch target: IMD's oracle signer fixed, no constructor arguments |

## What `settle()` checks

1. **Right question.** The prefix hashes to the vault's `prefixHash`, and the attestation's `questionHash` equals `keccak256(prefix + '{"fromBlock":F,"toBlock":T}}')`. IMD's question hash is keccak256 of the request's canonical JSON (sorted keys, no whitespace) over answerType, chainId, definitions, evidence, question, v and window. Window sorts last, so the contract appends it.
2. **Right shape.** answerType 3 (uint256), a 32-byte answer, chainId equal to this chain.
3. **A real panel.** panelSize ≥ 5, agreed ≥ 4, agreed ≥ quorum.
4. **Fresh.** `block.timestamp <= expiresAt`.
5. **Signed by IMD.** EIP-712 domain `IdentityMD Oracle` version `2`, this contract as verifyingContract.
6. **Recent and in order.** Every attestation, including the baseline, must have `toBlock <= block.number` and be at most 600 blocks old when settled. The first attestation after creation is the baseline; each verdict's toBlock is ≥ 6,000 blocks after the last; the count never goes down. Future windows revert with `TooEarly`; windows more than 600 blocks old revert with `AttestationExpired`.

`MIN_SPACING` assumes 12-second blocks, so this version is for Ethereum mainnet and Sepolia only.

Keepers must request a recent window and settle within 600 blocks of its end (about two hours at 12 seconds per block). After an outage, request one fresh verdict; do not backfill missed windows with the current live count. Remaining tranches still go to `missTo` after the deadline.

Tokens that block transfers to the builder, funder or burn recipient can prevent payouts. In particular, blocking a refund recipient can leave both settlement and expiry reverting with funds locked. There is no recipient replacement or recovery path; token transfer restrictions are a funding risk.

## Golden vectors

`test/GoldenVectors.t.sol` pins the contract to IMD's real data:

- the question hash of IMD oracle request `5d9dbfd5-493b-47d3-bb4d-5d6652aa1ce9`;
- recovery of IMD's signer `0x5598…2982` from that request's real (version 1) attestation;
- our version 2 digest against an independent EIP-712 implementation (Python eth_account);
- recovery of IMD's signer from a real version 2 attestation (request `16051ac5-3319-479c-ac22-9ca9a11cd727`) through the contract's own `attestationDigest`.

## Launch

Through the IMD swarm, as the hackathon requires:

1. `POST /requests/import` with this repo and `kind: "contracts"`.
2. `POST /requests/check` with a `launch.open` body: `onchain: "evm_contracts"`, `chainId: 1`, `contracts: ["src/ShipOrBurnIMD.sol"]`, plus the `repoUrl` and `baseCommit` from step 1.
3. Pay 0.5 IMD and follow `GET /launches/:id` until it reads live.

`foundry.toml` keeps `bytecode_hash = "none"`, which IMD requires for imported projects. `script/Deploy.s.sol` is for local and Sepolia iteration only.
