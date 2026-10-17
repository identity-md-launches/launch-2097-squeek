// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SqueekToken} from "../src/SqueekToken.sol";

/// @title DeploySqueekToken
/// @notice Reviewable deployment script for `SqueekToken`.
/// @dev The IdentityMD launch does not use this script: the factory deploys the token from its
/// creation code and receives the supply as `msg.sender`. This script exists so a reviewer or an
/// operator on a test network can reproduce that deployment. The token takes no constructor
/// arguments, so there is no configuration to read: `deploy()` is the whole procedure and tests
/// call it directly. `run()` only wraps it in a broadcast.
contract DeploySqueekToken is Script {
    /// @notice Deploys the token. Whoever is `msg.sender` for the creation receives the supply.
    function deploy() public returns (SqueekToken token) {
        token = new SqueekToken();
    }

    /// @notice Broadcast entry point: deploys with the signer forge was given on the command line.
    function run() external returns (SqueekToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
