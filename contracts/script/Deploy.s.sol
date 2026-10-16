// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TCH8} from "../src/TCH8.sol";
import {Sale} from "../src/Sale.sol";
import {Escrow} from "../src/Escrow.sol";

/// forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
/// Deploys TCH8, Sale and Escrow, authorises Sale and Escrow as minters, and writes
/// the addresses to ../frontend/src/deployed.json. The deployer becomes Admin and Operator.
contract Deploy is Script {
    uint256 constant MAX_SUPPLY = 1_000_000_000e6; // 1 billion TCH8 (6 decimals)
    uint256 constant PRICE_WEI_PER_TCH8 = 0.0001 ether; // 1 ETH = 10,000 TCH8  (1 TCH8 = 0.0001 ETH)

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);

        vm.startBroadcast(pk);
        TCH8 token = new TCH8("TCH8 Token", "TCH8", admin, MAX_SUPPLY);
        Sale sale = new Sale(address(token), admin, PRICE_WEI_PER_TCH8);
        Escrow escrow = new Escrow(address(token), admin, admin);
        token.addMinter(address(sale));   // Sale mints TCH8 when users pay ETH
        token.addMinter(address(escrow)); // Escrow burns TCH8 when exchange requests are paid
        vm.stopBroadcast();

        console.log("Admin/Operator:", admin);
        console.log("TCH8  :", address(token));
        console.log("Sale  :", address(sale));
        console.log("Escrow:", address(escrow));

        string memory json = string.concat(
            '{ "token": "', vm.toString(address(token)),
            '", "sale": "', vm.toString(address(sale)),
            '", "escrow": "', vm.toString(address(escrow)), '" }'
        );
        vm.writeFile("../frontend/src/deployed.json", json);
    }
}
