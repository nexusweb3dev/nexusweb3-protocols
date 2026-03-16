// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentVaultFactory} from "../src/AgentVaultFactory.sol";

contract DeployAgentVault is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(10)); // 0.1% default

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentVaultFactory factory = new AgentVaultFactory(deployer, feeRecipient, feeBps);
        console.log("AgentVaultFactory deployed at:", address(factory));
        console.log("  owner:", deployer);
        console.log("  feeRecipient:", feeRecipient);
        console.log("  feeBps:", feeBps);

        vm.stopBroadcast();
    }
}
