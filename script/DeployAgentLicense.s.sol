// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentLicense} from "../src/AgentLicense.sol";

contract DeployAgentLicense is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("LICENSE_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentLicense l = new AgentLicense(IERC20(BASE_USDC), treasury, deployer, 100);
        console.log("AgentLicense deployed at:", address(l));

        vm.stopBroadcast();
    }
}
