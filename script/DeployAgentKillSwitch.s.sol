// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentKillSwitch} from "../src/AgentKillSwitch.sol";

contract DeployAgentKillSwitch is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("KILLSWITCH_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentKillSwitch ks = new AgentKillSwitch(treasury, deployer, 0.01 ether);
        console.log("AgentKillSwitch deployed at:", address(ks));

        vm.stopBroadcast();
    }
}
