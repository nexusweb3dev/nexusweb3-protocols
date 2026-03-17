// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentBounty} from "../src/AgentBounty.sol";

contract DeployAgentBounty is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("BOUNTY_TREASURY", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentBounty b = new AgentBounty(IERC20(BASE_USDC), treasury, deployer, 200);
        console.log("AgentBounty deployed at:", address(b));

        vm.stopBroadcast();
    }
}
