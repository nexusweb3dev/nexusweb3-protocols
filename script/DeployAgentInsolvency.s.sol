// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentInsolvency} from "../src/AgentInsolvency.sol";

contract DeployAgentInsolvency is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("INSOLVENCY_TREASURY", deployer);
        uint256 feeBps = vm.envOr("INSOLVENCY_FEE_BPS", uint256(100)); // 1%
        uint256 regFee = vm.envOr("INSOLVENCY_REG_FEE", uint256(0.001 ether));
        address usdcAddr = vm.envOr("PAYMENT_TOKEN", BASE_USDC);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentInsolvency insolvency = new AgentInsolvency(
            IERC20(usdcAddr),
            treasury,
            deployer,
            feeBps,
            regFee
        );

        console.log("AgentInsolvency deployed at:", address(insolvency));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  paymentToken:", usdcAddr);
        console.log("  feeBps:", feeBps);
        console.log("  registrationFee:", regFee);

        vm.stopBroadcast();
    }
}
