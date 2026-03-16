// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentMarket} from "../src/AgentMarket.sol";

contract DeployAgentMarket is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("MARKET_TREASURY", deployer);
        uint256 feeBps = vm.envOr("MARKET_FEE_BPS", uint256(100)); // 1% default
        address usdcAddr = vm.envOr("PAYMENT_TOKEN", BASE_USDC);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentMarket market = new AgentMarket(IERC20(usdcAddr), treasury, deployer, feeBps);

        console.log("AgentMarket deployed at:", address(market));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  paymentToken:", usdcAddr);
        console.log("  platformFeeBps:", feeBps);

        vm.stopBroadcast();
    }
}
