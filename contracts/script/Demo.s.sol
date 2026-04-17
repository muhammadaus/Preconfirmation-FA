// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PendingTransfers} from "../src/PendingTransfers.sol";

/// @notice Post-deploy on-chain demo for PendingTransfers on Base Sepolia.
///         Exercises the two "happy" state transitions on a live testnet:
///           (0) fund wallet 2 from wallet 1 so it can pay gas
///           (1) happy path:    w1 creates -> w2 claims
///           (2) cancel path:   w1 creates -> w1 cancels
///
/// Branches NOT covered by this script (covered by the Foundry test suite):
///   - wrong-secret revert    (test_claim_revert_wrongSecret, or see cast commands
///                             in the README for a manual on-chain demo)
///   - expired-claim revert   (test_claim_revert_afterExpiry — uses vm.warp;
///                             reproducing on live chain would need a >10min wait)
///   - reentrancy             (test_reentrancy_protection — uses a malicious ERC20)
///
/// Env vars required:
///   PRIVATE_KEY1              — sender / deployer (wallet 1)
///   PRIVATE_KEY2              — receiver (wallet 2)
///   PENDING_TRANSFERS_ADDRESS — deployed PendingTransfers address
///
/// Usage:
///   forge script script/Demo.s.sol --rpc-url base_sepolia --broadcast
contract Demo is Script {
    uint256 constant AMT         = 0.0001 ether; // 1e14 wei
    uint256 constant FUND_TO_W2  = 0.0005 ether;
    uint64  constant EXP_LONG    = 1 hours;

    PendingTransfers pt;
    uint256 pk1;
    uint256 pk2;
    address w1;
    address w2;

    function _secret(uint256 salt) internal view returns (bytes32) {
        return keccak256(abi.encode("preconf-demo", block.timestamp, salt));
    }

    function _commit(bytes32 id, bytes32 secret) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, secret));
    }

    function run() external {
        pt  = PendingTransfers(payable(vm.envAddress("PENDING_TRANSFERS_ADDRESS")));
        pk1 = vm.envUint("PRIVATE_KEY1");
        pk2 = vm.envUint("PRIVATE_KEY2");
        w1  = vm.addr(pk1);
        w2  = vm.addr(pk2);

        console.log("=== Preconfirmation-FA demo ===");
        console.log("contract :", address(pt));
        console.log("wallet 1 :", w1);
        console.log("wallet 2 :", w2);
        console.log("w1 bal   :", w1.balance);
        console.log("w2 bal   :", w2.balance);

        _fundW2();
        _happyPath();
        _cancelPath();

        console.log("=== demo complete ===");
    }

    /*──────────── (0) fund wallet 2 ────────────*/
    function _fundW2() internal {
        if (w2.balance >= 0.0002 ether) {
            console.log("[0] skip funding, w2 already has", w2.balance);
            return;
        }
        console.log("[0] funding w2 with", FUND_TO_W2);
        vm.startBroadcast(pk1);
        (bool ok,) = w2.call{value: FUND_TO_W2}("");
        require(ok, "fund w2 failed");
        vm.stopBroadcast();
    }

    /*──────────── (1) happy path ────────────*/
    function _happyPath() internal {
        console.log("[1] happy: w1 creates, w2 claims");
        bytes32 secret = _secret(1);
        bytes32 preview = pt.previewId(w1, w2, address(0), AMT);
        bytes32 commit = _commit(preview, secret);
        vm.startBroadcast(pk1);
        bytes32 id = pt.createETH{value: AMT}(w2, commit, uint64(block.timestamp + EXP_LONG));
        vm.stopBroadcast();
        console.log("    created id:", vm.toString(id));

        vm.startBroadcast(pk2);
        pt.claim(id, secret);
        vm.stopBroadcast();
        console.log("    claimed by w2");
    }

    /*──────────── (2) cancel path ────────────*/
    function _cancelPath() internal {
        console.log("[2] cancel: w1 creates, w1 cancels");
        bytes32 secret = _secret(2);
        bytes32 preview = pt.previewId(w1, w2, address(0), AMT);
        bytes32 commit = _commit(preview, secret);
        vm.startBroadcast(pk1);
        bytes32 id = pt.createETH{value: AMT}(w2, commit, uint64(block.timestamp + EXP_LONG));
        pt.cancel(id);
        vm.stopBroadcast();
        console.log("    created + cancelled id:", vm.toString(id));
    }
}
