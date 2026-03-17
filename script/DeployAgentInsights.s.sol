// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentInsights} from "../src/AgentInsights.sol";

contract DeployAgentInsights is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("INSIGHTS_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentInsights i = new AgentInsights(treasury, deployer, 0.001 ether);
        console.log("AgentInsights deployed at:", address(i));

        vm.stopBroadcast();
    }
}
