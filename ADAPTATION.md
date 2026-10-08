# ShipOrBurnIMD launch adaptation

The sole launch target remains `src/ShipOrBurnIMD.sol:ShipOrBurnIMD` on Ethereum
mainnet (chain ID 1), with no constructor arguments and zero deployment value.
Its source file is unchanged. Its inherited settlement logic has the minimal
freshness fix required by the reproduced high-severity finding below.

The constructor already meets the factory requirements: it configures the fixed
IMD signer and EIP-712 domain locally, makes no external calls, needs no code at
another address, and creates no other contract. There is no owner, admin,
initializer, pause, upgrade, or factory privilege. No token, distributor, or pool
was added to the launch. Test tokens and the factory probe are test fixtures only.

## Changes and reasons

| File | Change and requirement |
| --- | --- |
| `src/ShipOrBurn.sol` | Before recording a baseline or verdict, reject `toBlock > block.number` with the existing `TooEarly` error, and reject `block.number - toBlock > 600` with the existing `AttestationExpired` error. Required by high finding `fafebc306dda`. The future check precedes subtraction, so subtraction cannot underflow. |
| `test/ShipOrBurn.t.sol` | Advance block number and time in existing lifecycle tests, which previously settled future windows without advancing the simulated chain. Preserve all original assertions. Add six freshness regressions covering burn/refund catch-up, future baseline/verdict, stale baseline, the inclusive 600-block limit, rejection at 601 blocks, unchanged state on rejection, and expiry of remaining funds. Add three tests reproducing the unchanged blocklist and `issuedAt` observations. |
| `test/ShipOrBurnIMD.t.sol` | Rehearse zero-value CREATE2 deployment through a factory with no constructor arguments or initialization calls. Check the predicted address, mainnet domain, fixed signer, empty initial vault set, code-size limits, and the protected floor's instruction-aware forbidden-opcode scan. |
| `README.md` | Describe the freshness checks, existing errors, keeper recovery after an outage, and the reproduced token-blocklist limitation. |
| `ADAPTATION.md` | Record the required change rationale, audit dispositions, compatibility, and local verification. |

No function signature, struct, event, error declaration, constant, typehash, or
storage layout changed. Both compiled application ABIs were compared with their
pre-edit artifacts and are identical. The signer remains
`0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`; the domain remains
`IdentityMD Oracle`, version `2`, with this contract as `verifyingContract`.
The golden-vector tests and question-hash implementation are unchanged.
Build configuration and vendored dependencies are unchanged; nothing was installed.

The 600-block allowance follows the audit's suggested bound (about two hours at
12 seconds per block), well below `MIN_SPACING` of 6,000 blocks. It also applies
to baselines, which would otherwise allow the same catch-up problem. Keepers must
settle a recent window; after an outage they request one fresh verdict instead of
backfilling historical windows with today's count. Remaining funds still expire
to `missTo`. This bounds the window's age at settlement; it does not independently
prove when GitHub was read or replace trust in IMD's signed evidence.

## Imported audit dispositions

- **High — `fafebc306ddaa2183fc62de86b4cac86760aa243a61755acfe5d35e99153fbc6`: reproduced and fixed.**
  The supplied proof was copied unchanged to scratch and run before the source
  edit. It failed with `1000000000000000000 != 0`: a tranche went to the burn
  recipient after two requests made at the same live count but naming windows
  6,000 blocks apart. After the fix, that exact proof passes. Permanent tests
  reject the stale request, accept the fresh request, pay the builder once, leave
  two tranches in custody, and exercise expiry for both burn and refund vaults.
  Contract-side acceptance of future windows was also reproduced and is now
  rejected until the window ends. Whether the live IMD service would sign a
  future window was not tested and is not needed to reproduce the stale-window
  exploit.
- **Low — `1f8d8df336b074cb86aed2daba7fa5df7ddd4c89245550ab7b84eb819ee866d7`: reproduced, behavior unchanged.**
  Blocking the refund recipient after funding causes both a flat settlement and
  expiry to revert, leaving the vault open and fully funded. Blocking the builder
  prevents a shipped payout; expiry to an unblocked burn recipient still works.
  Both cases have retained tests and a README warning. The brief permits contract
  changes only for critical/high issues and preserves fixed payout recipients and
  the ABI, so no withdrawal, recipient replacement, or administrative escape was
  introduced.
- **Info — `6bbc85ac150928ed619ec3864966eeccc367f52b1d7b8f66b634ae8c6bd548db`: reproduced, behavior unchanged.**
  A correctly signed, otherwise valid baseline with `issuedAt = type(uint64).max`
  and an unexpired `expiresAt` is accepted. A retained test documents this
  difference from the canonical consumer's five-minute future tolerance. The
  signer remains trusted to set issuance time; no critical/high exploit was
  reproduced from this observation.
- **Info — `2d0343953c4ca4d02ba351964f9a85edf7ba46685f1ba12b48ffc437a8ff66f2`: coverage statement, not a defect.**
  The original 25 tests passed before adaptation. The source review, factory
  rehearsal, ABI comparison, unchanged real-signature vectors, and conservation
  fuzz test support the relevant launch checks. No production role, external
  constructor dependency, or forbidden escape mechanism was found. This does
  not claim to reproduce another reviewer's historical read coverage or verify
  live panel behavior for unusual quorum configurations.

None of the three behavioral observations was dismissed as non-reproducing.
The task's explicit fixed signer, permissionless settlement, shared-attestation
reuse, and exact ABI take precedence over the generic oracle-consumer examples
that add owners, signer rotation, intake calls, callbacks, or global consumption.

## Verification and handoff

- `forge build`: passes with the project's solc 0.8.26, optimizer 200 runs,
  Cancun EVM, and `bytecode_hash = "none"`. Forge emits lint warnings, not build
  errors; timestamp deadlines, exact deposit balance checks, and JSON hash
  construction retain their existing semantics.
- `forge test`: 36 passing tests including the unchanged scratch exploit proof;
  35 retained tests after scratch is excluded, including all original 25 tests
  and all four golden-vector tests. Conservation fuzzing uses the configured
  1,000 runs.
- The factory rehearsal deploys an 11,170-byte creation artifact with a
  10,187-byte runtime, below the 49,152/24,576-byte limits. Its deployed runtime
  passes the protected floor's scan for DELEGATECALL, CALLCODE, and SELFDESTRUCT.
- Tests use local fixtures and require no network, keys, or environment values.
  No Slither/Mythril run or live oracle request was performed.

This worker prepared and checked the repository locally. It did not broadcast a
deployment or write `launch.json`; the subsequent manifest step should list only
`ShipOrBurnIMD` with an empty `constructorArgs` array. Deployment and explorer
verification remain with the launch service.
