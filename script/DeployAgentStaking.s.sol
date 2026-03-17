// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentStaking} from "../src/AgentStaking.sol";

contract DeployAgentStaking is Script {
    address constant NEXUS_TOKEN = 0x7a75B5a885e847Fc4a3098CB3C1560CBF6A8112e;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("STAKING_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentStaking s = new AgentStaking(IERC20(NEXUS_TOKEN), treasury, deployer);
        console.log("AgentStaking deployed at:", address(s));

        vm.stopBroadcast();
    }
}
