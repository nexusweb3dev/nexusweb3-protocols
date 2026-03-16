// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {NexusToken} from "../src/NexusToken.sol";

contract DeployNexusToken is Script {
    uint256 constant DEFAULT_SUPPLY = 100_000_000e18; // 100M NEXUS

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address recipient = vm.envOr("TOKEN_RECIPIENT", deployer);
        uint256 totalSupply = vm.envOr("NEXUS_TOTAL_SUPPLY", DEFAULT_SUPPLY);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        NexusToken nexus = new NexusToken(recipient, totalSupply);

        console.log("NexusToken deployed at:", address(nexus));
        console.log("  recipient:", recipient);
        console.log("  totalSupply:", totalSupply);

        vm.stopBroadcast();
    }
}
