// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentReferral} from "../src/AgentReferral.sol";

contract DeployAgentReferral is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 referralBps = vm.envOr("REFERRAL_BPS", uint256(1000)); // 10%
        address usdcAddr = vm.envOr("PAYMENT_TOKEN", BASE_USDC);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentReferral referralContract = new AgentReferral(
            IERC20(usdcAddr),
            deployer,
            referralBps
        );

        console.log("AgentReferral deployed at:", address(referralContract));
        console.log("  owner:", deployer);
        console.log("  paymentToken:", usdcAddr);
        console.log("  referralBps:", referralBps);

        vm.stopBroadcast();
    }
}
