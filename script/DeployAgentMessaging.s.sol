// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentMessaging} from "../src/AgentMessaging.sol";

contract DeployAgentMessaging is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("MESSAGING_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentMessaging m = new AgentMessaging(treasury, deployer, 0.0001 ether);
        console.log("AgentMessaging deployed at:", address(m));

        vm.stopBroadcast();
    }
}
