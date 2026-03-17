// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentVoting} from "../src/AgentVoting.sol";

contract DeployAgentVoting is Script {
    address constant REPUTATION = 0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("VOTING_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentVoting v = new AgentVoting(REPUTATION, treasury, deployer, 0.001 ether, 0.0001 ether);
        console.log("AgentVoting deployed at:", address(v));

        vm.stopBroadcast();
    }
}
