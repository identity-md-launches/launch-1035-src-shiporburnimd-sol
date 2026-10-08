// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ShipOrBurn} from "src/ShipOrBurn.sol";

contract CustodyTestToken is ERC20 {
    constructor() ERC20("Custody test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev The base contract contains all vault logic. A test-only signer lets random
/// attestations exercise real ECDSA verification without changing production code.
/// GoldenVectors.t.sol separately checks the deployed IMD variant and real signatures.
abstract contract ShipOrBurnTestSupport is Test {
    uint256 internal constant ORACLE_KEY = 0xA11CE;

    function _question(string memory repo) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                '{"answerType":"uint256","chainId":',
                vm.toString(block.chainid),
                ',"evidence":"panel","question":"Total merged pull requests in ',
                repo,
                '?","v":1,"window":'
            )
        );
    }

    function _attestation(ShipOrBurn sob, bytes memory prefix, uint64 toBlock, uint256 count)
        internal
        view
        returns (ShipOrBurn.Attestation memory a)
    {
        a.requestId = keccak256(abi.encode(prefix, toBlock, count));
        a.chainId = block.chainid;
        a.fromBlock = toBlock - 1;
        a.toBlock = toBlock;
        a.questionHash = sob.questionHash(prefix, a.fromBlock, toBlock);
        a.answerType = 3;
        a.answer = abi.encode(count);
        a.figure = count;
        a.blockHash = keccak256(abi.encode(toBlock));
        a.panelJobId = keccak256(abi.encode(a.requestId));
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
    }

    function _sign(ShipOrBurn sob, ShipOrBurn.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_KEY, sob.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _advance(uint256 toBlock) internal {
        if (toBlock > vm.getBlockNumber()) {
            vm.warp(vm.getBlockTimestamp() + (toBlock - vm.getBlockNumber()) * 12);
            vm.roll(toBlock);
        }
    }
}
