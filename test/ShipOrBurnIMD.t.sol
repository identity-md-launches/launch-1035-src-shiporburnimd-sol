// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ShipOrBurnIMD} from "../src/ShipOrBurnIMD.sol";

/// @dev Models the launch factory's zero-value CREATE2, with no initialization call.
contract ShipOrBurnFactoryProbe {
    function deploy(bytes32 salt) external returns (ShipOrBurnIMD) {
        return new ShipOrBurnIMD{salt: salt}();
    }
}

contract ShipOrBurnIMDTest is Test {
    function test_constructorCreatesOnlyTheApplicationAndMakesNoExternalCalls() public {
        vm.chainId(1);
        ShipOrBurnFactoryProbe factory = new ShipOrBurnFactoryProbe();
        vm.startStateDiffRecording();
        ShipOrBurnIMD sob = factory.deploy(keccak256("constructor call trace"));
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 creations;
        uint256 calls;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory access = accesses[i];
            if (access.kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertEq(access.account, address(sob));
                assertEq(access.accessor, address(factory));
                assertEq(access.value, 0);
            } else if (access.kind == VmSafe.AccountAccessKind.Call) {
                ++calls;
                assertEq(access.account, address(factory), "constructor called an external dependency");
                assertEq(access.accessor, address(this));
            } else {
                assertTrue(
                    access.kind != VmSafe.AccountAccessKind.StaticCall
                        && access.kind != VmSafe.AccountAccessKind.DelegateCall
                        && access.kind != VmSafe.AccountAccessKind.CallCode
                        && access.kind != VmSafe.AccountAccessKind.SelfDestruct,
                    "unexpected constructor interaction"
                );
            }
        }
        assertEq(creations, 1, "constructor created another contract");
        assertEq(calls, 1, "only the test's factory call is expected");
        assertEq(sob.vaultCount(), 0);
    }

    function test_usesImdSigner() public {
        ShipOrBurnIMD sob = new ShipOrBurnIMD();
        assertEq(sob.attester(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        (, string memory name, string memory version,,,,) = sob.eip712Domain();
        assertEq(name, "IdentityMD Oracle");
        assertEq(version, "2");
    }

    function test_factoryDeploysOnlyShipOrBurnIMDWithoutDependencies() public {
        vm.chainId(1);
        ShipOrBurnFactoryProbe factory = new ShipOrBurnFactoryProbe();
        bytes32 salt = keccak256("ShipOrBurnIMD factory rehearsal");
        bytes memory creationCode = type(ShipOrBurnIMD).creationCode;
        assertLe(creationCode.length, 49_152);
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(creationCode)))))
        );

        ShipOrBurnIMD sob = factory.deploy(salt);
        assertEq(address(sob), predicted);
        assertEq(sob.attester(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(sob.attester().code.length, 0, "deployment needs no signer contract");
        assertEq(sob.vaultCount(), 0);
        assertEq(address(sob).balance, 0);
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) = sob.eip712Domain();
        assertEq(name, "IdentityMD Oracle");
        assertEq(version, "2");
        assertEq(chainId, 1);
        assertEq(verifyingContract, address(sob));

        // Same instruction-aware size/opcode check as the supplied protected floor.
        bytes memory code = address(sob).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
