// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentAuditLog} from "../src/AgentAuditLog.sol";

contract DeployAgentAuditLog is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("AUDITLOG_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentAuditLog al = new AgentAuditLog(treasury, deployer, 0.0001 ether);
        console.log("AgentAuditLog deployed at:", address(al));

        vm.stopBroadcast();
    }
}
