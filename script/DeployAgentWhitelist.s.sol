// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentWhitelist} from "../src/AgentWhitelist.sol";

contract DeployAgentWhitelist is Script {
    address constant REGISTRY = 0x6F73c4e1609b8f16a6e6B9227B9e7B411bFDeC60;
    address constant REPUTATION = 0x08Facfe3E32A922cB93560a7e2F7ACFaD8435f16;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("WHITELIST_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentWhitelist wl = new AgentWhitelist(REGISTRY, REPUTATION, treasury, deployer, 0.01 ether);
        console.log("AgentWhitelist deployed at:", address(wl));

        vm.stopBroadcast();
    }
}
