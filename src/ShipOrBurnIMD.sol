// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ShipOrBurn} from "./ShipOrBurn.sol";

/// @title Ship or Burn, wired to IMD's oracle signer
/// @notice The contract the swarm launches. No constructor arguments: the IMD signer is fixed.
contract ShipOrBurnIMD is ShipOrBurn {
    /// @dev The `attester` that api.imd.fun reports for every oracle request.
    address public constant IMD_ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    constructor() ShipOrBurn(IMD_ORACLE_SIGNER) {}
}
