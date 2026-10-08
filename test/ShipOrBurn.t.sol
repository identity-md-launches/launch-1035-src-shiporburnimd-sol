// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShipOrBurn} from "../src/ShipOrBurn.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Identity.md", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Takes 1% on every transfer, so a vault would be underfunded.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract ShipOrBurnTest is Test {
    uint256 constant SIGNER_PK = 0xA11CE;
    uint128 constant TRANCHE = 1e18;
    uint16 constant TRANCHES = 3;

    ShipOrBurn sob;
    MockToken imd;
    address signer;
    address funder = makeAddr("funder");
    address builder = makeAddr("builder");
    bytes prefix;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_100_000);
        vm.warp(1_791_500_000);
        signer = vm.addr(SIGNER_PK);
        sob = new ShipOrBurn(signer);
        imd = new MockToken();
        imd.mint(funder, 100e18);
        vm.prank(funder);
        imd.approve(address(sob), type(uint256).max);
        prefix = _prefix("shiporburn/ship-or-burn");
    }

    // ------------------------------------------------------------ helpers

    /// The production question: total merged pull requests, counted at retrieval.
    function _prefix(string memory repo) internal pure returns (bytes memory) {
        return bytes(
            string.concat(
                '{"answerType":"uint256","chainId":1,"definitions":{"count":"The total_count field returned by https://api.github.com/search/issues?q=repo:',
                repo,
                '+is:pr+is:merged at retrieval. Every merged pull request in the repository counts, whatever its base branch.","missing":"If the repository is missing or private, or the API errors or rate-limits, report unavailable. Never guess, and never answer 0 for a failure.","window":"The block window is context only. The answer is the count at the moment you retrieve it."},"evidence":"panel","question":"How many pull requests in the GitHub repository ',
                repo,
                ' have been merged, counted when you retrieve the evidence?","v":1,"window":'
            )
        );
    }

    function _create(bool refund) internal returns (uint256 id) {
        vm.prank(funder);
        id = sob.createVault(imd, builder, refund, TRANCHE, TRANCHES, uint64(block.timestamp + 10 days), prefix);
    }

    function _att(bytes memory p, uint64 toBlock, uint256 count)
        internal
        view
        returns (ShipOrBurn.Attestation memory a)
    {
        uint64 fromBlock = toBlock - 300;
        a = ShipOrBurn.Attestation({
            requestId: bytes32(uint256(toBlock)),
            chainId: 1,
            questionHash: sob.questionHash(p, fromBlock, toBlock),
            answerType: 3,
            answer: abi.encode(count),
            figure: count,
            fromBlock: fromBlock,
            toBlock: toBlock,
            blockHash: keccak256(abi.encode(toBlock)),
            panelJobId: bytes32(uint256(toBlock) << 128),
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 7 days)
        });
    }

    function _sign(ShipOrBurn.Attestation memory a, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, sob.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _settle(uint256 id, uint64 toBlock, uint256 count) internal {
        ShipOrBurn.Attestation memory a = _att(prefix, toBlock, count);
        sob.settle(id, a, _sign(a, SIGNER_PK), prefix);
    }

    // ------------------------------------------------------------ lifecycle

    function test_shipMissShip_thenClosed() public {
        uint256 id = _create(false);
        uint64 b = uint64(block.number);

        _settle(id, b + 10, 7); // baseline: 7 merged PRs
        _settle(id, b + 6_010, 8); // shipped
        _settle(id, b + 12_010, 8); // flat: burned
        _settle(id, b + 18_010, 9); // shipped

        assertEq(imd.balanceOf(builder), 2 * TRANCHE);
        assertEq(imd.balanceOf(sob.DEAD()), TRANCHE);
        assertEq(imd.balanceOf(address(sob)), 0);

        ShipOrBurn.Vault memory v = sob.getVault(id);
        assertEq(v.settled, 3);
        assertEq(v.shipped, 2);
        assertEq(v.streak, 1);
        assertTrue(v.closed);

        ShipOrBurn.Attestation memory a = _att(prefix, b + 24_010, 10);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.VaultClosed.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_refundVault_sendsMissesToFunder() public {
        uint256 id = _create(true);
        uint64 b = uint64(block.number);
        uint256 funderBefore = imd.balanceOf(funder);
        _settle(id, b + 10, 7);
        _settle(id, b + 6_010, 7);
        assertEq(imd.balanceOf(funder), funderBefore + TRANCHE);
        assertEq(imd.balanceOf(sob.DEAD()), 0);
    }

    function test_emitsVerdictEvents() public {
        uint256 id = _create(false);
        uint64 b = uint64(block.number);
        _settle(id, b + 10, 7);

        ShipOrBurn.Attestation memory a = _att(prefix, b + 6_010, 8);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectEmit(address(sob));
        emit ShipOrBurn.Shipped(id, 1, 8, TRANCHE, 1, a.requestId);
        sob.settle(id, a, sig, prefix);

        a = _att(prefix, b + 12_010, 8);
        sig = _sign(a, SIGNER_PK);
        vm.expectEmit(address(sob));
        emit ShipOrBurn.Missed(id, 2, 8, TRANCHE, sob.DEAD(), a.requestId);
        sob.settle(id, a, sig, prefix);
    }

    // ------------------------------------------------------------ the six checks

    function test_rejectsAnotherQuestion() public {
        uint256 id = _create(false);
        bytes memory other = _prefix("someone/else");
        ShipOrBurn.Attestation memory a = _att(other, uint64(block.number) + 10, 1);
        bytes memory sig = _sign(a, SIGNER_PK);

        vm.expectRevert(ShipOrBurn.WrongQuestion.selector);
        sob.settle(id, a, sig, other); // prefix is not the vault's

        vm.expectRevert(ShipOrBurn.WrongQuestion.selector);
        sob.settle(id, a, sig, prefix); // hash is for another question
    }

    function test_rejectsTamperedWindow() public {
        uint256 id = _create(false);
        ShipOrBurn.Attestation memory a = _att(prefix, uint64(block.number) + 10, 1);
        a.toBlock += 1; // the hash no longer matches the window it claims
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.WrongQuestion.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_rejectsNonUintAnswer() public {
        uint256 id = _create(false);
        ShipOrBurn.Attestation memory a = _att(prefix, uint64(block.number) + 10, 1);
        a.answerType = 0;
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.BadAnswer.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_rejectsWeakPanels() public {
        uint256 id = _create(false);
        uint64 t = uint64(block.number) + 10;

        ShipOrBurn.Attestation memory a = _att(prefix, t, 1);
        a.panelSize = 4;
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.WeakPanel.selector);
        sob.settle(id, a, sig, prefix);

        a = _att(prefix, t, 1);
        a.agreed = 3;
        a.quorum = 3;
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.WeakPanel.selector);
        sob.settle(id, a, sig, prefix);

        a = _att(prefix, t, 1);
        a.panelSize = 9;
        a.quorum = 7;
        a.agreed = 6; // the deployer's rerun decided: not the panel's own agreement
        sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.WeakPanel.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_rejectsExpiredAttestation() public {
        uint256 id = _create(false);
        ShipOrBurn.Attestation memory a = _att(prefix, uint64(block.number) + 10, 1);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.warp(a.expiresAt + 1);
        vm.expectRevert(ShipOrBurn.AttestationExpired.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_rejectsForgedSignature() public {
        uint256 id = _create(false);
        ShipOrBurn.Attestation memory a = _att(prefix, uint64(block.number) + 10, 1);
        bytes memory sig = _sign(a, 0xBAD);
        vm.expectRevert(ShipOrBurn.BadSignature.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_rejectsReplayAndTooSoon() public {
        uint256 id = _create(false);
        uint64 b = uint64(block.number);
        ShipOrBurn.Attestation memory base = _att(prefix, b + 10, 7);
        bytes memory baseSig = _sign(base, SIGNER_PK);
        sob.settle(id, base, baseSig, prefix);

        vm.expectRevert(ShipOrBurn.TooSoon.selector);
        sob.settle(id, base, baseSig, prefix); // replay

        ShipOrBurn.Attestation memory early = _att(prefix, b + 5_999, 8);
        bytes memory earlySig = _sign(early, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.TooSoon.selector);
        sob.settle(id, early, earlySig, prefix); // under 20 hours later
    }

    function test_rejectsCountGoingDown() public {
        uint256 id = _create(false);
        uint64 b = uint64(block.number);
        _settle(id, b + 10, 7);
        ShipOrBurn.Attestation memory a = _att(prefix, b + 6_010, 6);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.CountWentDown.selector);
        sob.settle(id, a, sig, prefix);
    }

    function test_baselineMustPostdateVault() public {
        uint256 id = _create(false);
        ShipOrBurn.Attestation memory a = _att(prefix, uint64(block.number) - 1, 7);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.TooEarly.selector);
        sob.settle(id, a, sig, prefix);
    }

    // ------------------------------------------------------------ deadline

    function test_expire_sendsTheRestToMissTo() public {
        uint256 id = _create(false);
        uint64 b = uint64(block.number);
        _settle(id, b + 10, 7);
        _settle(id, b + 6_010, 8);

        vm.expectRevert(ShipOrBurn.NotYet.selector);
        sob.expire(id);

        vm.warp(block.timestamp + 10 days + 1);
        ShipOrBurn.Attestation memory a = _att(prefix, b + 12_010, 9);
        bytes memory sig = _sign(a, SIGNER_PK);
        vm.expectRevert(ShipOrBurn.PastDeadline.selector);
        sob.settle(id, a, sig, prefix);

        sob.expire(id);
        assertEq(imd.balanceOf(builder), TRANCHE);
        assertEq(imd.balanceOf(sob.DEAD()), 2 * TRANCHE);
        assertEq(imd.balanceOf(address(sob)), 0);

        vm.expectRevert(ShipOrBurn.VaultClosed.selector);
        sob.expire(id);
    }

    // ------------------------------------------------------------ creation

    function test_rejectsBadPrefixes() public {
        bytes memory boolQuestion = bytes(string.concat('{"answerType":"bool"', string(_slice(prefix, 23))));
        bytes memory otherChain =
            bytes(string.concat('{"answerType":"uint256","chainId":8453', string(_slice(prefix, 35))));
        bytes memory noWindow = _slice(prefix, 0, prefix.length - 10);
        bytes[3] memory bad = [boolQuestion, otherChain, noWindow];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(funder);
            vm.expectRevert(ShipOrBurn.BadPrefix.selector);
            sob.createVault(imd, builder, false, TRANCHE, TRANCHES, uint64(block.timestamp + 10 days), bad[i]);
        }
    }

    /// The prefix used here is byte-identical to tools/question.mjs (`node question.mjs prefix shiporburn/ship-or-burn`).
    function test_prefixMatchesQuestionTool() public view {
        assertEq(keccak256(prefix), 0xdb02167fa266e567cdf99c4bf4d81550cfad978830934bd98e3c028ee9a38bfd);
    }

    function test_rejectsBadParams() public {
        vm.expectRevert(ShipOrBurn.BadParams.selector);
        new ShipOrBurn(address(0));

        uint64 deadline = uint64(block.timestamp + 10 days);
        vm.startPrank(funder);
        vm.expectRevert(ShipOrBurn.BadParams.selector);
        sob.createVault(IERC20(address(0)), builder, false, TRANCHE, TRANCHES, deadline, prefix);
        vm.expectRevert(ShipOrBurn.BadParams.selector);
        sob.createVault(imd, address(0), false, TRANCHE, TRANCHES, deadline, prefix);
        vm.expectRevert(ShipOrBurn.BadParams.selector);
        sob.createVault(imd, builder, false, 0, TRANCHES, deadline, prefix);
        vm.expectRevert(ShipOrBurn.BadParams.selector);
        sob.createVault(imd, builder, false, TRANCHE, 0, deadline, prefix);
        vm.stopPrank();
    }

    function test_rejectsShortDeadline() public {
        vm.prank(funder);
        vm.expectRevert(ShipOrBurn.DeadlineTooSoon.selector);
        sob.createVault(imd, builder, false, TRANCHE, TRANCHES, uint64(block.timestamp + 2 days), prefix);
    }

    function test_rejectsFeeOnTransferTokens() public {
        FeeToken fee = new FeeToken();
        fee.mint(funder, 100e18);
        vm.startPrank(funder);
        fee.approve(address(sob), type(uint256).max);
        vm.expectRevert(ShipOrBurn.UnsupportedToken.selector);
        sob.createVault(
            IERC20(address(fee)), builder, false, TRANCHE, TRANCHES, uint64(block.timestamp + 10 days), prefix
        );
        vm.stopPrank();
    }

    function test_onlyFunderLinksSchedule() public {
        uint256 id = _create(false);
        vm.expectRevert(ShipOrBurn.NotFunder.selector);
        sob.linkSchedule(id, "3b589ab6-de1e-416c-ac37-1fca5aef3179");
        vm.prank(funder);
        sob.linkSchedule(id, "3b589ab6-de1e-416c-ac37-1fca5aef3179");
    }

    // ------------------------------------------------------------ fuzz

    /// Tokens are only ever released, missed, or still locked: nothing is created or lost.
    function testFuzz_conservation(uint256 seed, uint8 verdicts) public {
        uint256 id = _create(false);
        uint64 t = uint64(block.number) + 10;
        uint256 count = seed % 1000;
        _settle(id, t, count);
        uint256 n = bound(verdicts, 0, TRANCHES);
        for (uint256 i; i < n; ++i) {
            t += 6_000 + uint64(uint256(keccak256(abi.encode(seed, i))) % 2_000);
            if (uint256(keccak256(abi.encode(seed, i, "ship"))) % 2 == 0) count += 1 + (seed % 3);
            _settle(id, t, count);
        }
        ShipOrBurn.Vault memory v = sob.getVault(id);
        uint256 total = uint256(TRANCHE) * TRANCHES;
        assertEq(imd.balanceOf(builder) + imd.balanceOf(sob.DEAD()) + imd.balanceOf(address(sob)), total);
        assertEq(imd.balanceOf(builder), uint256(v.shipped) * TRANCHE);
        assertEq(imd.balanceOf(address(sob)), uint256(TRANCHES - v.settled) * TRANCHE);
    }

    function _slice(bytes memory b, uint256 start) internal pure returns (bytes memory) {
        return _slice(b, start, b.length);
    }

    function _slice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[start + i];
        }
    }
}
