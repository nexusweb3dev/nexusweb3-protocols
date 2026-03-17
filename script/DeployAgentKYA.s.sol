// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentKYA} from "../src/AgentKYA.sol";

contract DeployAgentKYA is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("KYA_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentKYA k = new AgentKYA(IERC20(BASE_USDC), treasury, deployer, 10_000_000);
        console.log("AgentKYA deployed at:", address(k));

        vm.stopBroadcast();
    }
}
