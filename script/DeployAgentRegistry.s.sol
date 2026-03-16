// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";

contract DeployAgentRegistry is Script {
    // Base mainnet USDC
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("REGISTRY_TREASURY", deployer);
        uint256 regFee = vm.envOr("REGISTRATION_FEE", uint256(5_000_000)); // $5 USDC
        uint256 renewFee = vm.envOr("RENEWAL_FEE", uint256(1_000_000)); // $1 USDC
        address usdcAddr = vm.envOr("PAYMENT_TOKEN", BASE_USDC);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentRegistry registry = new AgentRegistry(
            IERC20(usdcAddr),
            treasury,
            deployer,
            regFee,
            renewFee
        );

        console.log("AgentRegistry deployed at:", address(registry));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  paymentToken:", usdcAddr);
        console.log("  registrationFee:", regFee);
        console.log("  renewalFee:", renewFee);

        vm.stopBroadcast();
    }
}
