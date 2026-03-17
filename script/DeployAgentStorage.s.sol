// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentStorage} from "../src/AgentStorage.sol";

contract DeployAgentStorage is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("STORAGE_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentStorage s = new AgentStorage(treasury, deployer, 0.0001 ether);
        console.log("AgentStorage deployed at:", address(s));

        vm.stopBroadcast();
    }
}
