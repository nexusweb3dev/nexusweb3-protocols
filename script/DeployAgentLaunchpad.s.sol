// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentLaunchpad} from "../src/AgentLaunchpad.sol";

contract DeployAgentLaunchpad is Script {
    uint256 constant DEFAULT_LAUNCH_FEE = 0.01 ether;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("LAUNCHPAD_TREASURY", deployer);
        uint256 launchFee = vm.envOr("LAUNCH_FEE", DEFAULT_LAUNCH_FEE);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentLaunchpad launchpad = new AgentLaunchpad(treasury, deployer, launchFee);

        console.log("AgentLaunchpad deployed at:", address(launchpad));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  launchFee:", launchFee);

        vm.stopBroadcast();
    }
}
