// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentReputation} from "../src/AgentReputation.sol";

contract DeployAgentReputation is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("REPUTATION_TREASURY", deployer);
        uint256 queryFee = vm.envOr("QUERY_FEE", uint256(0.001 ether));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentReputation rep = new AgentReputation(treasury, deployer, queryFee);
        console.log("AgentReputation deployed at:", address(rep));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  queryFee:", queryFee);

        vm.stopBroadcast();
    }
}
