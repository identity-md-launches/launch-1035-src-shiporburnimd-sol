// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ShipOrBurn} from "../src/ShipOrBurn.sol";

/// @dev IMD's version-1 attestation (signed before 2026-09-30): no panelSize, quorum or agreed.
///      Used only to prove our field encoding against a real signature from IMD's signer.
contract V1Harness is EIP712 {
    bytes32 constant TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
    );

    struct V1 {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    constructor() EIP712("IdentityMD Oracle", "1") {}

    function signer(V1 calldata a, bytes calldata sig) external view returns (address) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    TYPEHASH, a.requestId, a.chainId, a.questionHash, a.answerType, keccak256(a.answer), a.figure
                ),
                abi.encode(a.fromBlock, a.toBlock, a.blockHash, a.panelJobId, a.issuedAt, a.expiresAt)
            )
        );
        return ECDSA.recover(_hashTypedDataV4(structHash), sig);
    }
}

/// @notice Golden vectors taken from IMD's public API (oracle request 5d9dbfd5-493b-47d3-bb4d-5d6652aa1ce9).
contract GoldenVectorsTest is Test {
    address constant IMD_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant REAL_CONSUMER = 0x892abA33239D8f274Eeb05176e27CC7dc08AA351;

    ShipOrBurn sob;

    function setUp() public {
        vm.chainId(1);
        sob = new ShipOrBurn(IMD_SIGNER);
    }

    /// questionHash = keccak256 of the request's canonical JSON, window last.
    function test_questionHash_matchesRealImdRequest() public view {
        bytes memory prefix = bytes(
            '{"answerType":"bool","chainId":1,"definitions":{"calendar":"Use [2026-09-30T01:04:48.076Z, 2026-10-01T02:04:48.074Z). Blocks are context only.","missing":"Unavailable evidence is not false. Report inability rather than guessing.","project":"Fetch https://github.com and check: GitHub."},"evidence":"panel","question":"Does https://github.com serve content matching \\"GitHub\\" as of 2026-09-30T02:04:48.074Z?","v":1,"window":'
        );
        assertEq(
            sob.questionHash(prefix, 26079414, 26086885),
            0x53bbaac72127e4ca33546939a00eb61980d7c8a27685141aea15ba545c6eaf77
        );
    }

    /// Our struct encoding recovers IMD's real signer from a real attestation.
    function test_realImdSignatureRecovers() public {
        deployCodeTo("GoldenVectors.t.sol:V1Harness", REAL_CONSUMER);
        V1Harness.V1 memory a = V1Harness.V1({
            requestId: 0x5d9dbfd5493b47d3bb4d5d6652aa1ce900000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x53bbaac72127e4ca33546939a00eb61980d7c8a27685141aea15ba545c6eaf77,
            answerType: 0,
            answer: abi.encode(true),
            figure: 0,
            fromBlock: 26079414,
            toBlock: 26086885,
            blockHash: 0x09745a4b80f563e6c563f2e07daac2bd16b1b78a87ca264fc056e00cf06f65f3,
            panelJobId: 0x9de35c77142a4845a1ebfac712e4f97d00000000000000000000000000000000,
            issuedAt: 1790730547,
            expiresAt: 1791335347
        });
        bytes memory sig =
            hex"9c5ecbd3a85cfeb30f44ea3e07fb391fa47b3b751bd5414043f2217e28a4dc1753323fdb72871acabd3b390793d9de61154e2eb5f34b4d65d826637f3cc6e49b1b";
        assertEq(V1Harness(REAL_CONSUMER).signer(a, sig), IMD_SIGNER);
    }

    /// Our version-2 digest equals an independent EIP-712 implementation (Python eth_account).
    function test_v2DigestMatchesReference() public {
        address at = address(0x5B0B);
        deployCodeTo("ShipOrBurn.sol:ShipOrBurn", abi.encode(IMD_SIGNER), at);
        ShipOrBurn.Attestation memory a = ShipOrBurn.Attestation({
            requestId: 0x1111111111111111111111111111111100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0xabababababababababababababababababababababababababababababababab,
            answerType: 3,
            answer: abi.encode(uint256(42)),
            figure: 42,
            fromBlock: 26100000,
            toBlock: 26100300,
            blockHash: 0x2222222222222222222222222222222222222222222222222222222222222222,
            panelJobId: 0x3333333333333333333333333333333300000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1791500000,
            expiresAt: 1792104800
        });
        assertEq(
            ShipOrBurn(at).attestationDigest(a), 0x6f7562921feecb290f6b68ebea25b5b721c9a737dcda89a3ada1ef18ef315c5b
        );
    }

    /// The contract's own version-2 digest recovers IMD's real signer from a real version-2 attestation
    /// (oracle request 16051ac5-3319-479c-ac22-9ca9a11cd727, a uint256 panel answer).
    function test_realImdV2SignatureRecovers() public {
        address consumer = 0x37Bfb8AC7C960E558657871D41Ca70E07e7DbfFf;
        deployCodeTo("ShipOrBurn.sol:ShipOrBurn", abi.encode(IMD_SIGNER), consumer);
        ShipOrBurn.Attestation memory a = ShipOrBurn.Attestation({
            requestId: 0x16051ac53319479cac229ca9a11cd72700000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x39eecf277118e4219d50e4352a2fcf943cf802239c546d54dd4baba53c72d787,
            answerType: 3,
            answer: abi.encode(uint256(3582834000)),
            figure: 3582834000,
            fromBlock: 26122900,
            toBlock: 26122901,
            blockHash: 0x22cd78830715d67d27849123a084fe3b854a1af74b40cd7f73c727399eef3059,
            panelJobId: 0xb9b745c20a1241b5a9d3c921cbafe9c900000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 4,
            issuedAt: 1791417448,
            expiresAt: 1791439048
        });
        bytes memory sig =
            hex"94d3d979ccf52901db4f6f21f07cd8e123f46f69a8aac9e79a88dcc40475c67317174ffbce45766f075a5865ff9837b33f88f0f6da770f498ca703ae0927bfb11c";
        assertEq(ECDSA.recover(ShipOrBurn(consumer).attestationDigest(a), sig), IMD_SIGNER);
    }
}
