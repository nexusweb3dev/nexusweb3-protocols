// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentGovernance} from "../src/AgentGovernance.sol";

contract DeployAgentGovernance is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address nexusToken = vm.envAddress("NEXUS_TOKEN");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentGovernance governance = new AgentGovernance(IERC20(nexusToken), deployer);

        console.log("AgentGovernance deployed at:", address(governance));
        console.log("  owner:", deployer);
        console.log("  nexusToken:", nexusToken);

        vm.stopBroadcast();
    }
}
