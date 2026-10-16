// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Escrow} from "../src/Escrow.sol";

/// Operator only. REDEMPTION_ID=0 APPROVE=true forge script script/ProcessRedemption.s.sol --rpc-url sepolia --broadcast
/// APPROVE=true  -> you paid the seller off-chain, burns the locked TCH8
/// APPROVE=false -> rejects and returns the TCH8 to the seller
contract ProcessRedemption is Script {
    function run() external {
        Escrow escrow = Escrow(vm.envAddress("ESCROW_ADDRESS"));
        uint256 id = vm.envUint("REDEMPTION_ID");
        bool approve = vm.envBool("APPROVE");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        if (approve) escrow.confirmRedemption(id);
        else escrow.rejectRedemption(id);
        vm.stopBroadcast();
        console.log(approve ? "Redemption paid and burned:" : "Redemption rejected:", id);
    }
}
