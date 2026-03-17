// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentScheduler} from "../src/AgentScheduler.sol";

contract DeployAgentScheduler is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("SCHEDULER_TREASURY", deployer);
        uint256 schedFee = vm.envOr("SCHEDULING_FEE", uint256(0.001 ether));
        uint256 keeperReward = vm.envOr("KEEPER_REWARD", uint256(0.0001 ether));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentScheduler sched = new AgentScheduler(treasury, deployer, schedFee, keeperReward);
        console.log("AgentScheduler deployed at:", address(sched));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  schedulingFee:", schedFee);
        console.log("  keeperReward:", keeperReward);

        vm.stopBroadcast();
    }
}
