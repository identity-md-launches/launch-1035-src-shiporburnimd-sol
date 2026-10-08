# ShipOrBurnIMD test coverage

Run `forge build` and `forge test`. No RPC, environment variables, extra dependencies,
or network access are required.

The existing lifecycle and golden-vector tests remain in place. The v2 vectors now
exercise `ShipOrBurnIMD` directly, including the supplied protocol digest vector.
The deployment tests record the factory's constructor trace to check that it creates
only the application and makes no calls to external dependencies.

`ShipOrBurnAdversarial.t.sol` checks creation and permissionless expiry on the actual
production contract, full-width deposit arithmetic, boundary inputs, failed token
transfers and retries, signature and domain tampering, replay, and reentrant token
callbacks across all three custody functions.

`ShipOrBurnInvariant.t.sol` runs 256 random sequences of 64 calls. Its handler uses
four participants, an unrelated keeper, two independent tokens, multiple vaults,
refund and burn destinations, and direct token donations. Independent funding and
payout ledgers check custody and recipient balances after every call. It also checks
verdict state, rejected-call atomicity, and that closed vaults never change. Every
sequence ends by expiring all open vaults and checking that only donations remain.
Unexpected handler reverts fail the campaign. A deterministic handler test exercises
every economic transition as a check against vacuous coverage.

Random attestations use a known test signer with the unchanged `ShipOrBurn` base,
which implements all production vault logic. The suite does not impersonate IMD,
replace signature recovery, or modify production storage to manufacture signatures.
Fixed-signer deployment and the real IMD v2 signature are checked independently
against `ShipOrBurnIMD`. Standard ERC-20 custody properties do not extend support to
rebasing or recipient-blocking tokens, which the brief excludes.
