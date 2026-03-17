// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentSplit} from "../src/AgentSplit.sol";

contract DeployAgentSplit is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("SPLIT_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentSplit s = new AgentSplit(IERC20(BASE_USDC), treasury, deployer, 50, 0.001 ether);
        console.log("AgentSplit deployed at:", address(s));

        vm.stopBroadcast();
    }
}
