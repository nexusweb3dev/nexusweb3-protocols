// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentBridge} from "../src/AgentBridge.sol";

contract DeployAgentBridge is Script {
    uint256 constant DEFAULT_BRIDGE_FEE = 0.001 ether;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("BRIDGE_TREASURY", deployer);
        address relayer = vm.envOr("BRIDGE_RELAYER", deployer);
        uint256 bridgeFee = vm.envOr("BRIDGE_FEE", DEFAULT_BRIDGE_FEE);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentBridge bridge = new AgentBridge(treasury, relayer, deployer, bridgeFee);

        console.log("AgentBridge deployed at:", address(bridge));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  relayer:", relayer);
        console.log("  bridgeFee:", bridgeFee);

        vm.stopBroadcast();
    }
}
