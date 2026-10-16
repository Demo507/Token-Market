// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Sale} from "../src/Sale.sol";

/// NEW_PRICE_WEI = wei per 1 TCH8. Default is 100000000000000 (1 ETH = 10,000 TCH8).
/// Example: 200000000000000 = 1 ETH buys 5,000 TCH8.
/// forge script script/SetPrice.s.sol --rpc-url sepolia --broadcast
contract SetPrice is Script {
    function run() external {
        Sale sale = Sale(payable(vm.envAddress("SALE_ADDRESS")));
        uint256 newPrice = vm.envUint("NEW_PRICE_WEI");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        sale.setPrice(newPrice);
        vm.stopBroadcast();
        console.log("New price (wei per TCH8):", newPrice);
    }
}
