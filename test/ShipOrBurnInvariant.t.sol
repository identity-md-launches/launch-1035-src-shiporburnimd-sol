// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ShipOrBurn} from "src/ShipOrBurn.sol";
import {CustodyTestToken, ShipOrBurnTestSupport} from "./helpers/ShipOrBurnTestSupport.sol";

/// @dev Expected balances come from funded inputs and requested verdicts, never
/// from the vault's payout counters. Actors may fund each other's vaults, and the
/// same token backs many unrelated vaults. Donations are accounted for separately.
contract ShipOrBurnHandler is ShipOrBurnTestSupport {
    struct Position {
        uint256 tokenIndex;
        address funder;
        address builder;
        address missTo;
        uint128 tranche;
        uint16 tranches;
        uint64 deadline;
        bytes prefix;
        uint256 funded;
        uint256 builderPaid;
        uint256 missPaid;
        uint256 count;
        uint64 lastBlock;
        uint16 verdicts;
        uint16 ships;
        uint16 streak;
        bool baselined;
        bool closed;
        bytes32 closedState;
    }

    ShipOrBurn public immutable sob;
    CustodyTestToken[2] public tokens;
    address[4] public actors;
    address public immutable outsider;
    Position[] private positions;
    mapping(uint256 => mapping(address => uint256)) public expectedBalance;
    uint256[2] public minted;
    uint256[2] public deposits;
    uint256[2] public payouts;
    uint256[2] public donations;
    uint256 public baselines;
    uint256 public ships;
    uint256 public misses;
    uint256 public expiries;
    uint256 public rejections;

    constructor() {
        sob = new ShipOrBurn(vm.addr(ORACLE_KEY));
        outsider = makeAddr("invariant unrelated keeper");
        for (uint256 t; t < 2; ++t) {
            tokens[t] = new CustodyTestToken();
        }
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("invariant actor ", vm.toString(i)));
            for (uint256 t; t < 2; ++t) {
                vm.prank(actors[i]);
                tokens[t].approve(address(sob), type(uint256).max);
            }
        }
    }

    function create(uint128 amount, uint8 periods, uint256 actorSeed, uint256 tokenSeed, bool refund) public {
        if (positions.length == 24) return;
        Position memory p;
        p.tranche = uint128(bound(amount, 1, type(uint128).max));
        p.tranches = uint16(bound(periods, 1, 8));
        p.tokenIndex = tokenSeed % 2;
        p.funder = actors[actorSeed % 4];
        p.builder = actors[(actorSeed / 4) % 4];
        p.missTo = refund ? p.funder : sob.DEAD();
        p.funded = uint256(p.tranche) * p.tranches;
        // Extra room allows random delays while still reaching final verdicts.
        p.deadline = uint64(vm.getBlockTimestamp() + (uint256(p.tranches) + 1) * 20 hours + 5 days);
        p.prefix = _question(tokenSeed % 3 == 0 ? "test/shared" : "test/other");
        tokens[p.tokenIndex].mint(p.funder, p.funded);
        vm.prank(p.funder);
        uint256 id =
            sob.createVault(tokens[p.tokenIndex], p.builder, refund, p.tranche, p.tranches, p.deadline, p.prefix);
        assertEq(id, positions.length);
        positions.push(p);
        minted[p.tokenIndex] += p.funded;
        deposits[p.tokenIndex] += p.funded;
    }

    function verdict(uint256 seed, uint256 countSeed, bool ship, uint256 callerSeed) public {
        (bool found, uint256 id) = _openPosition(seed);
        if (!found) return;
        Position storage p = positions[id];
        if (vm.getBlockTimestamp() > p.deadline) {
            _expire(id, callerSeed);
            return;
        }
        if (p.baselined) _advance(uint256(p.lastBlock) + 6000);
        if (vm.getBlockTimestamp() > p.deadline) {
            _expire(id, callerSeed);
            return;
        }
        uint256 count = p.baselined ? p.count : bound(countSeed, 0, type(uint128).max);
        if (p.baselined && ship) count += bound(countSeed, 1, type(uint128).max);
        ShipOrBurn.Attestation memory a = _attestation(sob, p.prefix, uint64(vm.getBlockNumber()), count);
        bytes memory signature = _sign(sob, a);
        vm.prank(_caller(callerSeed));
        sob.settle(id, a, signature, p.prefix);
        if (!p.baselined) {
            p.baselined = true;
            ++baselines;
        } else {
            ++p.verdicts;
            if (ship) {
                ++p.ships;
                ++p.streak;
                ++ships;
                p.builderPaid += p.tranche;
                expectedBalance[p.tokenIndex][p.builder] += p.tranche;
            } else {
                p.streak = 0;
                ++misses;
                p.missPaid += p.tranche;
                expectedBalance[p.tokenIndex][p.missTo] += p.tranche;
            }
            payouts[p.tokenIndex] += p.tranche;
            if (p.verdicts == p.tranches) _markClosed(id);
        }
        p.count = count;
        p.lastBlock = uint64(vm.getBlockNumber());
    }

    function expire(uint256 seed, uint256 callerSeed) public {
        (bool found, uint256 id) = _openPosition(seed);
        if (!found) return;
        uint256 deadline = positions[id].deadline;
        if (vm.getBlockTimestamp() <= deadline) {
            uint256 secondsAhead = deadline + 1 - vm.getBlockTimestamp();
            // Ethereum-like block/time progression, without moving either backwards.
            vm.roll(vm.getBlockNumber() + (secondsAhead + 11) / 12);
            vm.warp(deadline + 1);
        }
        _expire(id, callerSeed);
    }

    function advanceTime(uint16 blocksAhead) public {
        _advance(vm.getBlockNumber() + bound(blocksAhead, 0, 6500));
    }

    function donate(uint128 amount, uint256 tokenSeed) public {
        uint256 t = tokenSeed % 2;
        uint256 value = bound(amount, 1, type(uint128).max);
        tokens[t].mint(address(this), value);
        tokens[t].transfer(address(sob), value);
        minted[t] += value;
        donations[t] += value;
    }

    /// Invalid calls use a real signature unless testing signature forgery. Every
    /// expected rejection checks both storage and all tracked token balances.
    function rejectInvalid(uint256 seed, uint8 kindSeed, uint256 callerSeed) public {
        if (positions.length == 0) return;
        uint256 id = seed % positions.length;
        Position storage p = positions[id];
        uint256 kind = kindSeed % 5;
        bytes32 beforeState = _snapshot(id);
        if (p.closed) {
            vm.expectRevert(ShipOrBurn.VaultClosed.selector);
            vm.prank(_caller(callerSeed));
            sob.expire(id);
        } else if (vm.getBlockTimestamp() > p.deadline) {
            ShipOrBurn.Attestation memory a = _attestation(sob, p.prefix, uint64(vm.getBlockNumber()), p.count);
            bytes memory signature = _sign(sob, a);
            vm.expectRevert(ShipOrBurn.PastDeadline.selector);
            vm.prank(_caller(callerSeed));
            sob.settle(id, a, signature, p.prefix);
        } else if (kind == 0) {
            vm.expectRevert(ShipOrBurn.NotYet.selector);
            vm.prank(_caller(callerSeed));
            sob.expire(id);
        } else {
            ShipOrBurn.Attestation memory a = _attestation(sob, p.prefix, uint64(vm.getBlockNumber()), p.count);
            bytes4 reason;
            if (kind == 1) {
                a.questionHash = bytes32(uint256(a.questionHash) ^ 1);
                reason = ShipOrBurn.WrongQuestion.selector;
            }
            if (kind == 2) {
                a.agreed = 3;
                reason = ShipOrBurn.WeakPanel.selector;
            }
            if (kind == 3) {
                a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
                reason = ShipOrBurn.AttestationExpired.selector;
            }
            bytes memory signature = _sign(sob, a);
            if (kind == 4) {
                a.figure += 1;
                reason = ShipOrBurn.BadSignature.selector;
            }
            vm.expectRevert(reason);
            vm.prank(_caller(callerSeed));
            sob.settle(id, a, signature, p.prefix);
        }
        assertEq(_snapshot(id), beforeState, "rejection changed state or balances");
        ++rejections;
    }

    function linkSchedule(uint256 seed, uint256 callerSeed) public {
        if (positions.length == 0) return;
        uint256 id = seed % positions.length;
        bytes32 beforeState = _snapshot(id);
        address caller = callerSeed % 2 == 0 ? positions[id].funder : outsider;
        if (caller == outsider) vm.expectRevert(ShipOrBurn.NotFunder.selector);
        vm.prank(caller);
        sob.linkSchedule(id, vm.toString(seed));
        assertEq(_snapshot(id), beforeState, "schedule changed custody");
    }

    function checkAccounting() external view {
        uint256[2] memory owed;
        for (uint256 i; i < positions.length; ++i) {
            Position storage p = positions[i];
            assertLe(p.builderPaid + p.missPaid, p.funded);
            uint256 remaining = p.funded - p.builderPaid - p.missPaid;
            if (p.closed) assertEq(remaining, 0, "closed vault owes funds");
            owed[p.tokenIndex] += remaining;
        }
        for (uint256 t; t < 2; ++t) {
            assertEq(tokens[t].balanceOf(address(sob)), owed[t] + donations[t], "custody differs from liabilities");
            assertEq(deposits[t], owed[t] + payouts[t], "funding not conserved");
            assertEq(tokens[t].totalSupply(), minted[t]);
            uint256 held = tokens[t].balanceOf(address(sob)) + tokens[t].balanceOf(sob.DEAD());
            for (uint256 actor; actor < actors.length; ++actor) {
                assertEq(
                    tokens[t].balanceOf(actors[actor]), expectedBalance[t][actors[actor]], "wrong beneficiary or amount"
                );
                held += tokens[t].balanceOf(actors[actor]);
            }
            assertEq(tokens[t].balanceOf(sob.DEAD()), expectedBalance[t][sob.DEAD()]);
            assertEq(tokens[t].balanceOf(outsider), 0, "keeper received vault funds");
            assertEq(tokens[t].balanceOf(address(this)), 0);
            assertEq(held, minted[t], "tokens escaped tracked custody");
        }
    }

    function checkStateMachine() external view {
        assertEq(sob.vaultCount(), positions.length);
        for (uint256 i; i < positions.length; ++i) {
            Position storage p = positions[i];
            ShipOrBurn.Vault memory v = sob.getVault(i);
            assertEq(v.closed, p.closed);
            assertEq(v.baselined, p.baselined);
            assertEq(v.settled, p.verdicts);
            assertEq(v.shipped, p.ships);
            assertEq(v.streak, p.streak);
            assertEq(v.lastCount, p.count);
            assertEq(v.lastToBlock, p.lastBlock);
            assertLe(v.shipped, v.settled);
            assertLe(v.settled, v.tranches);
            assertLe(v.streak, v.shipped);
            assertEq(v.funder, p.funder);
            assertEq(v.builder, p.builder);
            assertEq(v.missTo, p.missTo);
            assertEq(address(v.token), address(tokens[p.tokenIndex]));
            assertEq(v.tranche, p.tranche);
            assertEq(v.tranches, p.tranches);
            assertEq(v.deadline, p.deadline);
            assertEq(v.prefixHash, keccak256(p.prefix));
            if (p.closed) assertEq(keccak256(abi.encode(v)), p.closedState, "finished vault reopened or mutated");
            if (!p.closed) {
                assertEq(uint256(v.tranches - v.settled) * v.tranche, p.funded - p.builderPaid - p.missPaid);
            }
        }
    }

    /// End every random campaign by withdrawing all remaining liabilities. This
    /// checks exit liveness after arbitrary interleavings, including no baseline.
    function finish() external {
        for (uint256 i; i < positions.length; ++i) {
            if (!positions[i].closed) expire(i, 4);
        }
        for (uint256 t; t < 2; ++t) {
            assertEq(tokens[t].balanceOf(address(sob)), donations[t], "funded tokens remain after all exits");
            assertEq(deposits[t], payouts[t]);
        }
    }

    function _expire(uint256 id, uint256 callerSeed) private {
        Position storage p = positions[id];
        uint256 remaining = p.funded - p.builderPaid - p.missPaid;
        vm.prank(_caller(callerSeed));
        sob.expire(id);
        p.missPaid += remaining;
        expectedBalance[p.tokenIndex][p.missTo] += remaining;
        payouts[p.tokenIndex] += remaining;
        ++expiries;
        _markClosed(id);
    }

    function _markClosed(uint256 id) private {
        positions[id].closed = true;
        positions[id].closedState = keccak256(abi.encode(sob.getVault(id)));
    }

    function _caller(uint256 seed) private view returns (address) {
        return seed % 5 == 4 ? outsider : actors[seed % 4];
    }

    function _openPosition(uint256 seed) private view returns (bool found, uint256 id) {
        uint256 n = positions.length;
        for (uint256 i; i < n; ++i) {
            id = ((seed % n) + i) % n;
            if (!positions[id].closed) return (true, id);
        }
    }

    function _snapshot(uint256 id) private view returns (bytes32 digest) {
        digest = keccak256(abi.encode(sob.getVault(id), sob.vaultCount()));
        for (uint256 t; t < 2; ++t) {
            digest = keccak256(abi.encode(digest, tokens[t].balanceOf(address(sob)), tokens[t].balanceOf(sob.DEAD())));
            for (uint256 a; a < actors.length; ++a) {
                digest = keccak256(abi.encode(digest, tokens[t].balanceOf(actors[a])));
            }
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract ShipOrBurnInvariantTest is ShipOrBurnTestSupport {
    ShipOrBurnHandler internal handler;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_100_000);
        vm.warp(1_791_500_000);
        handler = new ShipOrBurnHandler();
        handler.create(1, 1, 4, 0, false);
        handler.create(type(uint128).max, 8, 9, 1, true);
        handler.create(1e18, 4, 14, 2, false);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.verdict.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.advanceTime.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.rejectInvalid.selector;
        selectors[6] = handler.linkSchedule.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_custodyEqualsOutstandingFundingPlusDonations() public view {
        handler.checkAccounting();
    }

    function invariant_vaultStateMatchesVerdictsAndClosedVaultsStayClosed() public view {
        handler.checkStateMachine();
    }

    function afterInvariant() public {
        handler.finish();
        handler.checkAccounting();
        handler.checkStateMachine();
    }

    /// Demonstrates reachability of every economic transition in the same harness
    /// used by the fuzzer, so a campaign of only rejected calls cannot look useful.
    function test_handlerReachesBaselineShipMissExpiryAndRejection() public {
        handler.verdict(0, 0, false, 4);
        handler.verdict(0, 1, true, 4);
        handler.verdict(1, 4, false, 3);
        handler.verdict(1, 1, false, 4);
        handler.verdict(1, 2, true, 0);
        handler.rejectInvalid(1, 4, 4);
        handler.donate(123, 0);
        handler.linkSchedule(1, 0);
        handler.expire(1, 4);
        handler.checkAccounting();
        handler.checkStateMachine();
        assertEq(handler.baselines(), 2);
        assertEq(handler.ships(), 2);
        assertEq(handler.misses(), 1);
        assertEq(handler.expiries(), 1);
        assertEq(handler.rejections(), 1);
    }
}
