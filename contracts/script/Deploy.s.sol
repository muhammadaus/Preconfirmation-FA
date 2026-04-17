// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PendingTransfers} from "../src/PendingTransfers.sol";

/// @notice Deploys PendingTransfers. Reads deployer key from the `PRIVATE_KEY1`
///         env var (per the project convention that wallet 1 is deployer + sender).
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url base_sepolia \
///     --broadcast \
///     --verify  (optional, needs BASESCAN_API_KEY)
///
/// The deployed address is printed to stdout; the broadcast artifact under
/// `broadcast/Deploy.s.sol/84532/run-latest.json` also records it for scripted reads.
contract Deploy is Script {
    function run() external returns (PendingTransfers deployed) {
        uint256 pk = vm.envUint("PRIVATE_KEY1");
        address deployer = vm.addr(pk);
        console.log("deployer:", deployer);
        console.log("chainid:", block.chainid);

        vm.startBroadcast(pk);
        deployed = new PendingTransfers();
        vm.stopBroadcast();

        console.log("PendingTransfers deployed at:", address(deployed));
    }
}
