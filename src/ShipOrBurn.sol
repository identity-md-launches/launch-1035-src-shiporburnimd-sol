// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Ship or Burn
/// @notice Vesting by shipping, verified by the IMD swarm.
/// @dev A vault holds `tranches * tranche` tokens. Each verdict is one IMD oracle attestation of a
///      counter (merged pull requests by default). If the counter went up since the last verdict,
///      one tranche goes to the builder; if not, one tranche goes to `missTo` (0xdEaD, or the funder
///      for refund vaults). Whatever is left at the deadline also goes to `missTo`.
///      The contract binds every attestation to the vault's own question by recomputing IMD's
///      questionHash on-chain: keccak256 of the request's canonical JSON, whose last key is the window.
///      No owner, no admin, no upgrade. Anyone can settle.
contract ShipOrBurn is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Field-for-field copy of IMD's OracleAttestation, EIP-712 domain "IdentityMD Oracle" version "2".
    struct Attestation {
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
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    struct Vault {
        IERC20 token;
        uint16 tranches; // verdicts the vault pays out over
        uint16 settled; // verdicts counted so far
        uint16 shipped; // verdicts that released a tranche
        uint16 streak; // current run of shipped verdicts
        bool baselined; // the first attestation sets the starting count
        bool closed;
        address funder;
        uint64 startBlock;
        address builder;
        uint64 lastToBlock; // toBlock of the last counted attestation
        address missTo;
        uint64 deadline; // unix seconds
        uint128 tranche; // tokens per verdict
        uint256 lastCount; // counter at the last counted attestation
        bytes32 prefixHash; // keccak256 of the canonical question prefix
    }

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    uint8 public constant ANSWER_UINT256 = 3;
    uint16 public constant MIN_PANEL = 5;
    uint16 public constant MIN_AGREED = 4;
    /// @notice Minimum blocks between counted verdicts: 6,000 blocks is at least 20 hours.
    uint64 public constant MIN_SPACING = 6_000;
    uint256 public constant MAX_PREFIX = 4_096;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice IMD's oracle signer. Ethereum mainnet: 0x5598aa9146215bc13eb26f2c692ad1461fd32982.
    address public immutable attester;

    Vault[] private _vaults;

    event VaultCreated(
        uint256 indexed id,
        address indexed token,
        address indexed builder,
        address funder,
        address missTo,
        uint256 tranche,
        uint16 tranches,
        uint64 deadline,
        bytes questionPrefix
    );
    event ScheduleLinked(uint256 indexed id, string scheduleId);
    event Baseline(uint256 indexed id, uint256 count, uint64 toBlock, bytes32 requestId);
    event Shipped(
        uint256 indexed id, uint16 indexed day, uint256 count, uint256 amount, uint16 streak, bytes32 requestId
    );
    event Missed(uint256 indexed id, uint16 indexed day, uint256 count, uint256 amount, address to, bytes32 requestId);
    event Expired(uint256 indexed id, uint256 amount, address to);

    error BadParams();
    error DeadlineTooSoon();
    error BadPrefix();
    error UnsupportedToken();
    error NotFunder();
    error VaultClosed();
    error PastDeadline();
    error NotYet();
    error WrongQuestion();
    error BadAnswer();
    error WeakPanel();
    error AttestationExpired();
    error BadSignature();
    error TooEarly();
    error TooSoon();
    error CountWentDown();

    constructor(address attester_) EIP712("IdentityMD Oracle", "2") {
        if (attester_ == address(0)) revert BadParams();
        attester = attester_;
    }

    // ---------------------------------------------------------------- vaults

    /// @notice Lock `tranche * tranches` of `token` for `builder`.
    /// @param refundMisses Missed tranches go back to the funder instead of 0xdEaD.
    /// @param questionPrefix The canonical JSON of the oracle request up to and including `"window":`.
    function createVault(
        IERC20 token,
        address builder,
        bool refundMisses,
        uint128 tranche,
        uint16 tranches,
        uint64 deadline,
        bytes calldata questionPrefix
    ) external nonReentrant returns (uint256 id) {
        if (address(token) == address(0) || builder == address(0) || tranche == 0 || tranches == 0) {
            revert BadParams();
        }
        // the baseline plus one verdict per tranche, each at least MIN_SPACING blocks (20h+) apart
        if (deadline < block.timestamp + (uint256(tranches) + 1) * 20 hours) revert DeadlineTooSoon();
        _checkPrefix(questionPrefix);

        uint256 total = uint256(tranche) * tranches;
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), total);
        if (token.balanceOf(address(this)) - balanceBefore != total) revert UnsupportedToken();

        address missTo = refundMisses ? msg.sender : DEAD;
        id = _vaults.length;
        _vaults.push(
            Vault({
                token: token,
                tranches: tranches,
                settled: 0,
                shipped: 0,
                streak: 0,
                baselined: false,
                closed: false,
                funder: msg.sender,
                startBlock: uint64(block.number),
                builder: builder,
                lastToBlock: 0,
                missTo: missTo,
                deadline: deadline,
                tranche: tranche,
                lastCount: 0,
                prefixHash: keccak256(questionPrefix)
            })
        );
        emit VaultCreated(id, address(token), builder, msg.sender, missTo, tranche, tranches, deadline, questionPrefix);
    }

    /// @notice Record which IMD schedule asks this vault's question. Informational only.
    function linkSchedule(uint256 id, string calldata scheduleId) external {
        if (msg.sender != _vaults[id].funder) revert NotFunder();
        emit ScheduleLinked(id, scheduleId);
    }

    /// @notice Count one IMD attestation for vault `id`. Permissionless.
    function settle(uint256 id, Attestation calldata a, bytes calldata signature, bytes calldata questionPrefix)
        external
        nonReentrant
    {
        Vault storage v = _vaults[id];
        if (v.closed) revert VaultClosed();
        if (block.timestamp > v.deadline) revert PastDeadline();

        // 1. the attestation answers this vault's question, about the window it names
        if (keccak256(questionPrefix) != v.prefixHash) revert WrongQuestion();
        if (a.questionHash != questionHash(questionPrefix, a.fromBlock, a.toBlock)) revert WrongQuestion();
        // 2. a single uint256 about this chain
        if (a.answerType != ANSWER_UINT256 || a.answer.length != 32 || a.chainId != block.chainid) {
            revert BadAnswer();
        }
        // 3. a real panel agreed
        if (a.panelSize < MIN_PANEL || a.agreed < MIN_AGREED || a.agreed < a.quorum) revert WeakPanel();
        // 4. still valid
        if (block.timestamp > a.expiresAt) revert AttestationExpired();
        // 5. signed by IMD
        if (ECDSA.recover(attestationDigest(a), signature) != attester) revert BadSignature();

        uint256 count = abi.decode(a.answer, (uint256));

        // 6. ordering: the first attestation after creation is the baseline, then one verdict per spacing
        if (!v.baselined) {
            if (a.toBlock < v.startBlock) revert TooEarly();
            v.baselined = true;
            v.lastCount = count;
            v.lastToBlock = a.toBlock;
            emit Baseline(id, count, a.toBlock, a.requestId);
            return;
        }
        if (a.toBlock < v.lastToBlock + MIN_SPACING) revert TooSoon();
        if (count < v.lastCount) revert CountWentDown();

        bool shipped = count > v.lastCount;
        uint16 day = ++v.settled;
        v.lastCount = count;
        v.lastToBlock = a.toBlock;
        if (v.settled == v.tranches) v.closed = true;

        if (shipped) {
            ++v.shipped;
            uint16 streak = ++v.streak;
            v.token.safeTransfer(v.builder, v.tranche);
            emit Shipped(id, day, count, v.tranche, streak, a.requestId);
        } else {
            v.streak = 0;
            v.token.safeTransfer(v.missTo, v.tranche);
            emit Missed(id, day, count, v.tranche, v.missTo, a.requestId);
        }
    }

    /// @notice After the deadline, send whatever is still locked to `missTo`. Permissionless.
    function expire(uint256 id) external nonReentrant {
        Vault storage v = _vaults[id];
        if (v.closed) revert VaultClosed();
        if (block.timestamp <= v.deadline) revert NotYet();
        v.closed = true;
        uint256 rest = uint256(v.tranches - v.settled) * v.tranche;
        if (rest > 0) v.token.safeTransfer(v.missTo, rest);
        emit Expired(id, rest, v.missTo);
    }

    // ---------------------------------------------------------------- views

    /// @notice IMD's questionHash: keccak256 of the request's canonical JSON. The keys sort as
    ///         answerType, chainId, definitions, evidence, question, v, window, so the window comes last.
    function questionHash(bytes calldata questionPrefix, uint64 fromBlock, uint64 toBlock)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                questionPrefix,
                '{"fromBlock":',
                Strings.toString(fromBlock),
                ',"toBlock":',
                Strings.toString(toBlock),
                "}}"
            )
        );
    }

    /// @notice The EIP-712 digest IMD signs for this contract.
    function attestationDigest(Attestation calldata a) public view returns (bytes32) {
        // two halves keep the stack shallow; abi.encode of static words concatenates exactly
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getVault(uint256 id) external view returns (Vault memory) {
        return _vaults[id];
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice The earliest toBlock the next verdict can use.
    function nextVerdictBlock(uint256 id) external view returns (uint64) {
        Vault storage v = _vaults[id];
        return v.baselined ? v.lastToBlock + MIN_SPACING : v.startBlock;
    }

    // ---------------------------------------------------------------- internal

    /// @dev The prefix must open a uint256 question about this chain and end right before the window.
    function _checkPrefix(bytes calldata p) private view {
        bytes memory head =
            bytes.concat('{"answerType":"uint256","chainId":', bytes(Strings.toString(block.chainid)), ",");
        bytes memory tail = ',"v":1,"window":';
        if (p.length > MAX_PREFIX || p.length <= head.length + tail.length) revert BadPrefix();
        if (keccak256(p[:head.length]) != keccak256(head)) revert BadPrefix();
        if (keccak256(p[p.length - tail.length:]) != keccak256(tail)) revert BadPrefix();
    }
}
