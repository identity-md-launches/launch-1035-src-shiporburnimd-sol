// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ShipOrBurn} from "src/ShipOrBurn.sol";
import {ShipOrBurnIMD} from "src/ShipOrBurnIMD.sol";
import {CustodyTestToken, ShipOrBurnTestSupport} from "./helpers/ShipOrBurnTestSupport.sol";

contract AdversarialCustodyToken is CustodyTestToken {
    // 1: reject; 2: move tokens then return false; 3: legacy ERC-20 with no return data.
    uint8 public transferMode;
    uint8 public transferFromMode;
    address public hookTarget;
    bytes public hookData;
    bool public hookAttempted;
    bool public hookSucceeded;
    bytes public hookResult;

    function setModes(uint8 outgoing, uint8 incoming) external {
        transferMode = outgoing;
        transferFromMode = incoming;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transferMode == 1) return false;
        super.transfer(to, amount);
        _callback();
        if (transferMode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return transferMode != 2;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (transferFromMode == 1) return false;
        super.transferFrom(from, to, amount);
        _callback();
        if (transferFromMode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return transferFromMode != 2;
    }

    function _callback() private {
        if (hookTarget != address(0)) {
            hookAttempted = true;
            (hookSucceeded, hookResult) = hookTarget.call(hookData);
        }
    }
}

abstract contract CustodyFixture is ShipOrBurnTestSupport {
    ShipOrBurn internal sob;
    AdversarialCustodyToken internal token;
    address internal funder;
    address internal builder;
    address internal keeper;
    bytes internal prefix;

    function setUp() public virtual {
        vm.chainId(1);
        vm.roll(26_100_000);
        vm.warp(1_791_500_000);
        funder = makeAddr("custody funder");
        builder = makeAddr("custody builder");
        keeper = makeAddr("permissionless keeper");
        sob = _deploy();
        token = new AdversarialCustodyToken();
        prefix = _question("test/repository");
        vm.prank(funder);
        token.approve(address(sob), type(uint256).max);
    }

    function _deploy() internal virtual returns (ShipOrBurn) {
        return new ShipOrBurn(vm.addr(ORACLE_KEY));
    }

    function _create(uint128 tranche, uint16 tranches, bool refund) internal returns (uint256 id) {
        token.mint(funder, uint256(tranche) * tranches);
        vm.prank(funder);
        id = sob.createVault(
            token,
            builder,
            refund,
            tranche,
            tranches,
            uint64(vm.getBlockTimestamp() + (uint256(tranches) + 1) * 20 hours),
            prefix
        );
    }

    function _settle(uint256 id, uint256 count) internal returns (ShipOrBurn.Attestation memory a) {
        _advance(sob.nextVerdictBlock(id));
        a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), count);
        bytes memory sig = _sign(sob, a);
        vm.prank(keeper);
        sob.settle(id, a, sig, prefix);
    }

    function _snapshot(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                sob.getVault(id),
                token.balanceOf(address(sob)),
                token.balanceOf(funder),
                token.balanceOf(builder),
                token.balanceOf(sob.DEAD())
            )
        );
    }

    function _reject(uint256 id, ShipOrBurn.Attestation memory a, bytes memory signature, bytes4 reason) internal {
        bytes32 beforeState = _snapshot(id);
        vm.expectRevert(reason);
        vm.prank(keeper);
        sob.settle(id, a, signature, prefix);
        assertEq(_snapshot(id), beforeState, "rejected attestation changed custody or vault");
    }
}

/// @dev Creation and expiry use the exact no-argument production deployment.
/// forge-config: default.fuzz.runs = 1000
contract ShipOrBurnIMDBoundariesTest is CustodyFixture {
    function _deploy() internal override returns (ShipOrBurn) {
        return new ShipOrBurnIMD();
    }

    function testFuzz_fullWidthDepositExpiresExactly(uint128 amount, uint16 periods, bool refund) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        periods = uint16(bound(periods, 1, type(uint16).max));
        _depositAndExpire(amount, periods, refund);
    }

    function test_oneWeiAndMaximumDeposit() public {
        _depositAndExpire(1, 1, false);
        _depositAndExpire(type(uint128).max, type(uint16).max, true);
    }

    function _depositAndExpire(uint128 amount, uint16 periods, bool refund) private {
        uint256 total = uint256(amount) * periods;
        uint256 beforeFunder = token.balanceOf(funder);
        uint256 beforeMiss = token.balanceOf(refund ? funder : sob.DEAD());
        uint256 id = _create(amount, periods, refund);
        ShipOrBurn.Vault memory v = sob.getVault(id);
        assertEq(v.funder, funder);
        assertEq(v.builder, builder);
        assertEq(address(v.token), address(token));
        assertEq(v.missTo, refund ? funder : sob.DEAD());
        assertEq(v.tranche, amount);
        assertEq(v.tranches, periods);
        assertEq(v.startBlock, vm.getBlockNumber());
        assertEq(v.prefixHash, keccak256(prefix));
        assertFalse(v.baselined);
        assertEq(token.balanceOf(funder), beforeFunder);
        assertEq(token.balanceOf(address(sob)), total);

        vm.warp(v.deadline);
        bytes32 beforeState = _snapshot(id);
        vm.expectRevert(ShipOrBurn.NotYet.selector);
        vm.prank(keeper);
        sob.expire(id);
        assertEq(_snapshot(id), beforeState);
        vm.warp(uint256(v.deadline) + 1);
        vm.expectEmit(address(sob));
        emit ShipOrBurn.Expired(id, total, v.missTo);
        vm.prank(keeper);
        sob.expire(id);
        assertTrue(sob.getVault(id).closed);
        assertEq(token.balanceOf(address(sob)), 0);
        assertEq(token.balanceOf(v.missTo), beforeMiss + total);
        assertEq(token.balanceOf(builder), 0);
        vm.expectRevert(ShipOrBurn.VaultClosed.selector);
        sob.expire(id);
    }

    function test_deadlineOneSecondTooShortIsAtomic() public {
        token.mint(funder, 3);
        vm.expectRevert(ShipOrBurn.DeadlineTooSoon.selector);
        vm.prank(funder);
        sob.createVault(token, builder, false, 1, 3, uint64(vm.getBlockTimestamp() + 80 hours - 1), prefix);
        assertEq(sob.vaultCount(), 0);
        assertEq(token.balanceOf(funder), 3);
    }

    function test_prefixLengthBoundaries() public {
        bytes memory head = bytes('{"answerType":"uint256","chainId":1,');
        bytes memory tail = bytes(',"v":1,"window":');
        bytes memory middle = new bytes(4096 - head.length - tail.length - bytes('"question":""').length);
        for (uint256 i; i < middle.length; ++i) {
            middle[i] = bytes1("x");
        }
        bytes memory maxPrefix = bytes.concat(head, '"question":"', middle, '"', tail);
        assertEq(maxPrefix.length, 4096);
        token.mint(funder, 10);
        vm.prank(funder);
        sob.createVault(token, builder, false, 1, 1, uint64(vm.getBlockTimestamp() + 40 hours), maxPrefix);
        assertEq(sob.getVault(0).prefixHash, keccak256(maxPrefix));

        bytes[4] memory invalid =
            [bytes(""), head, bytes.concat(head, tail), bytes.concat(head, '"question":"x', middle, '"', tail)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(ShipOrBurn.BadPrefix.selector);
            vm.prank(funder);
            sob.createVault(token, builder, false, 1, 1, uint64(vm.getBlockTimestamp() + 40 hours), invalid[i]);
        }
        assertEq(sob.vaultCount(), 1);
        assertEq(token.balanceOf(address(sob)), 1);
        assertEq(token.balanceOf(funder), 9);
    }

    function test_failedDepositsCannotCreateVaultOrConsumeFunds() public {
        token.mint(funder, 9);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            token.setModes(0, mode);
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
            vm.prank(funder);
            sob.createVault(token, builder, false, 3, 3, uint64(vm.getBlockTimestamp() + 80 hours), prefix);
            assertEq(sob.vaultCount(), 0);
            assertEq(token.balanceOf(address(sob)), 0);
            assertEq(token.balanceOf(funder), 9);
            assertEq(token.allowance(funder, address(sob)), type(uint256).max);
        }
    }

    function test_insufficientAllowanceAndBalanceAreAtomic() public {
        token.mint(funder, 8);
        vm.prank(funder);
        token.approve(address(sob), 8);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(sob), 8, 9)
        );
        vm.prank(funder);
        sob.createVault(token, builder, false, 3, 3, uint64(vm.getBlockTimestamp() + 80 hours), prefix);
        vm.prank(funder);
        token.approve(address(sob), 9);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", funder, 8, 9));
        vm.prank(funder);
        sob.createVault(token, builder, false, 3, 3, uint64(vm.getBlockTimestamp() + 80 hours), prefix);
        assertEq(sob.vaultCount(), 0);
        assertEq(token.balanceOf(funder), 8);
        assertEq(token.balanceOf(address(sob)), 0);
        assertEq(token.allowance(funder, address(sob)), 9);
    }

    function test_noReturnTokenCanFundAndExpire() public {
        token.setModes(3, 3);
        _depositAndExpire(17, 2, true);
    }

    function test_expiryTransferFailureRollsBackAndCanRetry() public {
        uint256 id = _create(17, 2, true);
        vm.warp(uint256(sob.getVault(id).deadline) + 1);
        bytes32 beforeState = _snapshot(id);
        token.setModes(2, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        sob.expire(id);
        assertEq(_snapshot(id), beforeState);
        token.setModes(0, 0);
        vm.prank(keeper);
        sob.expire(id);
        assertTrue(sob.getVault(id).closed);
        assertEq(token.balanceOf(funder), 34);
        assertEq(token.balanceOf(address(sob)), 0);
    }

    function test_scheduleEmitsWithoutChangingVaultEvenAfterExpiry() public {
        uint256 id = _create(7, 1, false);
        bytes32 beforeState = _snapshot(id);
        vm.expectEmit(address(sob));
        emit ShipOrBurn.ScheduleLinked(id, "scheduler-id");
        vm.prank(funder);
        sob.linkSchedule(id, "scheduler-id");
        assertEq(_snapshot(id), beforeState);
        vm.expectRevert(ShipOrBurn.NotFunder.selector);
        vm.prank(builder);
        sob.linkSchedule(id, "other");
        vm.warp(uint256(sob.getVault(id).deadline) + 1);
        sob.expire(id);
        beforeState = _snapshot(id);
        vm.prank(funder);
        sob.linkSchedule(id, "");
        assertEq(_snapshot(id), beforeState);
    }

    function test_deploymentDoesNotExposeAdministrationOrAcceptEther() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("setOracleSigner(address)", funder),
            abi.encodeWithSignature("upgradeTo(address)", funder),
            abi.encodeWithSignature("initialize(address)", funder)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(sob).call(calls[i]);
            assertFalse(ok);
        }
        vm.deal(address(this), 1);
        (bool accepted,) = address(sob).call{value: 1}("");
        assertFalse(accepted);
        assertEq(address(sob).balance, 0);
        assertEq(sob.attester(), ShipOrBurnIMD(address(sob)).IMD_ORACLE_SIGNER());
    }
}

/// forge-config: default.fuzz.runs = 1000
contract ShipOrBurnAttestationAdversarialTest is CustodyFixture {
    function test_allFifteenAttestationFieldsAreBoundToSignature() public {
        uint256 id = _create(100, 3, false);
        ShipOrBurn.Attestation memory original = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 7);
        bytes memory signature = _sign(sob, original);
        bytes32 digest = sob.attestationDigest(original);
        for (uint256 i; i < 15; ++i) {
            ShipOrBurn.Attestation memory a = abi.decode(abi.encode(original), (ShipOrBurn.Attestation));
            bytes4 reason = ShipOrBurn.BadSignature.selector;
            if (i == 0) a.requestId = bytes32(uint256(a.requestId) ^ 1);
            if (i == 1) {
                a.chainId = 11155111;
                reason = ShipOrBurn.BadAnswer.selector;
            }
            if (i == 2) {
                a.questionHash = bytes32(uint256(a.questionHash) ^ 1);
                reason = ShipOrBurn.WrongQuestion.selector;
            }
            if (i == 3) {
                a.answerType = 0;
                reason = ShipOrBurn.BadAnswer.selector;
            }
            if (i == 4) a.answer = abi.encode(uint256(8));
            if (i == 5) ++a.figure;
            if (i == 6) {
                --a.fromBlock;
                reason = ShipOrBurn.WrongQuestion.selector;
            }
            if (i == 7) {
                ++a.toBlock;
                reason = ShipOrBurn.WrongQuestion.selector;
            }
            if (i == 8) a.blockHash = bytes32(uint256(a.blockHash) ^ 1);
            if (i == 9) a.panelJobId = bytes32(uint256(a.panelJobId) ^ 1);
            if (i == 10) ++a.panelSize;
            if (i == 11) --a.quorum;
            if (i == 12) ++a.agreed;
            if (i == 13) --a.issuedAt;
            if (i == 14) ++a.expiresAt;
            assertNotEq(sob.attestationDigest(a), digest, "unsigned attestation field");
            _reject(id, a, signature, reason);
        }
        sob.settle(id, original, signature, prefix);
        assertTrue(sob.getVault(id).baselined);
        assertEq(sob.getVault(id).lastCount, 7);
        assertEq(token.balanceOf(address(sob)), 300);
    }

    function test_rejectsSignaturesForOtherConsumerOrDomainChain() public {
        uint256 id = _create(1, 1, false);
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 0);
        ShipOrBurn other = new ShipOrBurn(vm.addr(ORACLE_KEY));
        _reject(id, a, _sign(other, a), ShipOrBurn.BadSignature.selector);
        vm.chainId(11155111);
        bytes memory wrongChainSignature = _sign(sob, a);
        vm.chainId(1);
        _reject(id, a, wrongChainSignature, ShipOrBurn.BadSignature.selector);
        sob.settle(id, a, _sign(sob, a), prefix);
        assertTrue(sob.getVault(id).baselined);
    }

    function test_rejectsMalformedAndMalleableSignatures() public {
        uint256 id = _create(1, 1, false);
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 0);
        uint256[4] memory lengths = [uint256(0), 1, 64, 66];
        for (uint256 i; i < lengths.length; ++i) {
            bytes32 beforeState = _snapshot(id);
            vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, lengths[i]));
            sob.settle(id, a, new bytes(lengths[i]), prefix);
            assertEq(_snapshot(id), beforeState);
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_KEY, sob.attestationDigest(a));
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(order - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        sob.settle(id, a, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)), prefix);
        _reject(id, a, abi.encodePacked(r, s, uint8(0)), ECDSA.ECDSAInvalidSignature.selector);
        assertFalse(sob.getVault(id).baselined);
    }

    function testFuzz_rejectsNonWordAnswerLengths(uint8 size) public {
        uint256 length = bound(size, 0, 95);
        if (length >= 32) ++length;
        uint256 id = _create(1, 1, false);
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 0);
        a.answer = new bytes(length);
        _reject(id, a, _sign(sob, a), ShipOrBurn.BadAnswer.selector);
    }

    function test_exactSignatureExpiryAndDeadlineAreInclusive() public {
        uint256 id = _create(11, 1, false);
        _settle(id, 0);
        _advance(sob.nextVerdictBlock(id));
        vm.warp(sob.getVault(id).deadline);
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 1);
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        _reject(id, a, _sign(sob, a), ShipOrBurn.AttestationExpired.selector);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        bytes memory signature = _sign(sob, a);
        vm.prank(keeper);
        sob.settle(id, a, signature, prefix);
        assertEq(token.balanceOf(builder), 11);
        assertTrue(sob.getVault(id).closed);
    }

    function test_spacing5999Rejected6000AcceptedAndMaximumCountCannotWrap() public {
        uint256 id = _create(5, 2, false);
        _settle(id, 0);
        uint64 next = sob.nextVerdictBlock(id);
        _advance(next - 1);
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), type(uint256).max);
        _reject(id, a, _sign(sob, a), ShipOrBurn.TooSoon.selector);
        _settle(id, type(uint256).max);
        assertEq(token.balanceOf(builder), 5, "arbitrarily many merges pay only one tranche");
        _advance(sob.nextVerdictBlock(id));
        a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 0);
        _reject(id, a, _sign(sob, a), ShipOrBurn.CountWentDown.selector);
        _settle(id, type(uint256).max);
        assertEq(token.balanceOf(sob.DEAD()), 5);
        assertTrue(sob.getVault(id).closed);
    }

    function test_sameAttestationCanSettleTwoVaultsButCannotReplayEither() public {
        uint256 first = _create(11, 2, false);
        uint256 second = _create(23, 2, true);
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 4);
        bytes memory signature = _sign(sob, a);
        sob.settle(first, a, signature, prefix);
        sob.settle(second, a, signature, prefix);
        _advance(sob.nextVerdictBlock(first));
        a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 5);
        signature = _sign(sob, a);
        vm.prank(builder);
        sob.settle(first, a, signature, prefix);
        vm.prank(funder);
        sob.settle(second, a, signature, prefix);
        assertEq(token.balanceOf(builder), 34);
        _reject(first, a, signature, ShipOrBurn.TooSoon.selector);
        _reject(second, a, signature, ShipOrBurn.TooSoon.selector);
        assertEq(token.balanceOf(address(sob)), 34);
    }

    function testFuzz_failedVerdictTransferCanRetrySameSignature(bool shipped, bool refund) public {
        uint256 id = _create(13, 1, refund);
        _settle(id, 10);
        _advance(sob.nextVerdictBlock(id));
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), shipped ? 11 : 10);
        bytes memory signature = _sign(sob, a);
        bytes32 beforeState = _snapshot(id);
        token.setModes(2, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        sob.settle(id, a, signature, prefix);
        assertEq(_snapshot(id), beforeState, "failure must roll back closure, counters and token movement");
        token.setModes(0, 0);
        sob.settle(id, a, signature, prefix);
        assertEq(token.balanceOf(shipped ? builder : (refund ? funder : sob.DEAD())), 13);
        assertEq(token.balanceOf(address(sob)), 0);
        assertEq(sob.getVault(id).settled, 1);
        assertTrue(sob.getVault(id).closed);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_tokenCallbacksCannotReenterCustody(uint8 outerSeed, uint8 innerSeed) public {
        uint256 outer = bound(outerSeed, 0, 2);
        uint256 inner = bound(innerSeed, 0, 2);
        uint256 id = _create(19, 2, false);
        _settle(id, 3);
        _advance(sob.nextVerdictBlock(id));
        ShipOrBurn.Attestation memory a = _attestation(sob, prefix, uint64(vm.getBlockNumber()), 4);
        bytes memory signature = _sign(sob, a);
        bytes memory callback;
        if (inner == 0) {
            callback = abi.encodeCall(
                sob.createVault,
                (
                    IERC20(address(token)),
                    builder,
                    false,
                    uint128(19),
                    uint16(2),
                    uint64(vm.getBlockTimestamp() + 60 hours),
                    prefix
                )
            );
        }
        if (inner == 1) callback = abi.encodeCall(sob.settle, (id, a, signature, prefix));
        if (inner == 2) callback = abi.encodeCall(sob.expire, (id));
        token.setHook(address(sob), callback);
        if (outer == 0) {
            _create(19, 2, false);
            assertEq(sob.vaultCount(), 2);
            assertEq(token.balanceOf(address(sob)), 76);
        } else if (outer == 1) {
            sob.settle(id, a, signature, prefix);
            assertEq(token.balanceOf(builder), 19);
            assertEq(token.balanceOf(address(sob)), 19);
            assertEq(sob.getVault(id).settled, 1);
        } else {
            vm.warp(uint256(sob.getVault(id).deadline) + 1);
            sob.expire(id);
            assertEq(token.balanceOf(sob.DEAD()), 38);
            assertEq(token.balanceOf(address(sob)), 0);
            assertTrue(sob.getVault(id).closed);
        }
        assertTrue(token.hookAttempted(), "token callback was not exercised");
        assertFalse(token.hookSucceeded());
        assertEq(token.hookResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
