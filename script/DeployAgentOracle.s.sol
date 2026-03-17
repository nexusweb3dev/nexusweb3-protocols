// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentOracle} from "../src/AgentOracle.sol";

contract DeployAgentOracle is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envOr("ORACLE_TREASURY", deployer);
        uint256 queryFee = vm.envOr("ORACLE_QUERY_FEE", uint256(0.0005 ether));
        uint256 subPrice = vm.envOr("ORACLE_SUB_PRICE", uint256(1_000_000));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgentOracle oracleContract = new AgentOracle(
            IERC20(BASE_USDC), treasury, deployer, queryFee, subPrice
        );

        console.log("AgentOracle deployed at:", address(oracleContract));
        console.log("  owner:", deployer);
        console.log("  treasury:", treasury);
        console.log("  queryFee:", queryFee);
        console.log("  subPrice:", subPrice);

        vm.stopBroadcast();
    }
}
