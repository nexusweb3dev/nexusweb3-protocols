// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";

contract DeployAgentEscrow is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("ESCROW_TREASURY", deployer);
        uint256 feeBps = vm.envOr("ESCROW_FEE_BPS", uint256(50)); // 0.5%
        address usdcAddr = vm.envOr("PAYMENT_TOKEN", BASE_USDC);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentEscrow escrowContract = new AgentEscrow(IERC20(usdcAddr), treasury, deployer, feeBps);

        console.log("AgentEscrow deployed at:", address(escrowContract));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  paymentToken:", usdcAddr);
        console.log("  feeBps:", feeBps);

        vm.stopBroadcast();
    }
}
