// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ShipOrBurnIMD} from "../src/ShipOrBurnIMD.sol";

/// @notice For local and Sepolia iteration only. The hackathon entry is launched through the IMD swarm.
contract Deploy is Script {
    function run() external returns (ShipOrBurnIMD sob) {
        vm.startBroadcast();
        sob = new ShipOrBurnIMD();
        vm.stopBroadcast();
    }
}
