// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {PermitToken} from "../../test/v2/mocks/MockModules.sol";
import {DeployCore} from "./DeployCore.s.sol";

/// @title DeployLocal
/// @notice Anvil / testnet-without-USDC variant: deploys a mock 6-decimal USDC with EIP-2612 permit, mints 1,000,000 to
///         the first five anvil accounts, then deploys and wires the v2 core exactly like DeployCore.
///         Usage: PRIVATE_KEY=<anvil key 0> forge script script/v2/DeployLocal.s.sol \
///                --rpc-url http://127.0.0.1:8545 --broadcast
///         Optional: DEPLOY_JSON_PATH=deployments/v2-local.json (default v2-31337.json)
contract DeployLocal is DeployCore {
    address[5] internal ANVIL = [
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
        0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
        0x90F79bf6EB2c4f870365E785982E1f101E93b906,
        0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
    ];

    function run() external override returns (Deployed memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", deployer);
        address stakingRecipient = vm.envOr("STAKING_RECIPIENT", treasury);
        uint256 escrowFeeBps = vm.envOr("ESCROW_FEE_BPS", uint256(0));

        vm.startBroadcast(pk);
        PermitToken usdc = new PermitToken();
        for (uint256 i = 0; i < ANVIL.length; i++) {
            usdc.mint(ANVIL[i], 1_000_000_000_000); // 1,000,000 USDC
        }
        d = _deploy(deployer, treasury, stakingRecipient, address(0), address(0), address(usdc), 5000, 5000);
        _wire(d, escrowFeeBps);
        vm.stopBroadcast();

        console.log("MockUSDC          :", address(usdc));
        _print(d, deployer);
        _writeJson(d, deployer, treasury, address(usdc));
    }
}
