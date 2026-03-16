// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentYield} from "../src/AgentYield.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

contract DeployAgentYield is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant BASE_A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("YIELD_TREASURY", deployer);
        uint256 feeBps = vm.envOr("YIELD_FEE_BPS", uint256(1000)); // 10%

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentYield vault = new AgentYield(
            IERC20(BASE_USDC),
            IAavePool(BASE_AAVE_POOL),
            IERC20(BASE_A_USDC),
            treasury,
            deployer,
            feeBps
        );

        console.log("AgentYield deployed at:", address(vault));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  aavePool:", BASE_AAVE_POOL);
        console.log("  feeBps:", feeBps);

        vm.stopBroadcast();
    }
}
