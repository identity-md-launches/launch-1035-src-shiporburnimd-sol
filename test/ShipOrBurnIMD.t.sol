// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShipOrBurnIMD} from "../src/ShipOrBurnIMD.sol";

contract ShipOrBurnIMDTest is Test {
    function test_usesImdSigner() public {
        ShipOrBurnIMD sob = new ShipOrBurnIMD();
        assertEq(sob.attester(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        (, string memory name, string memory version,,,,) = sob.eip712Domain();
        assertEq(name, "IdentityMD Oracle");
        assertEq(version, "2");
    }
}
