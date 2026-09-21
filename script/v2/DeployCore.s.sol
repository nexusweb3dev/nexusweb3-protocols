// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentAccess} from "../../src/v2/AgentAccess.sol";
import {AgentIdentityV2} from "../../src/v2/AgentIdentityV2.sol";
import {AgentReputationV2} from "../../src/v2/AgentReputationV2.sol";
import {AgentKillSwitchV2} from "../../src/v2/AgentKillSwitchV2.sol";
import {AgentAuditLogV2} from "../../src/v2/AgentAuditLogV2.sol";
import {FeeRouter} from "../../src/v2/FeeRouter.sol";
import {AgentEscrowV2} from "../../src/v2/AgentEscrowV2.sol";
import {IAgentAccess} from "../../src/v2/interfaces/IAgentAccess.sol";

/// @title DeployCore
/// @notice Deploys the v2 core stack and wires every authorization in one broadcast, then writes
///         `deployments/v2-<chainId>.json`.
///
/// Env:
///   PRIVATE_KEY          deployer key (required)
///   OWNER                owner of all contracts (default: deployer)
///   TREASURY             fee treasury (default: owner)
///   STAKING_RECIPIENT    staking pool address for fee share (default: treasury)
///   REFERRAL             v1 AgentReferral address or 0 (default: 0)
///   ERC8004_REGISTRY     canonical ERC-8004 identity registry or 0 (default: 0)
///   PAYMENT_TOKEN        USDC (default: Base mainnet USDC)
///   STAKING_BPS          default 5000; TREASURY_BPS default 5000
///   ESCROW_FEE_BPS       default 0 (fee switch off)
contract DeployCore is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    struct Deployed {
        AgentAccess access;
        AgentIdentityV2 identity;
        AgentReputationV2 reputation;
        AgentKillSwitchV2 killSwitch;
        AgentAuditLogV2 auditLog;
        FeeRouter feeRouter;
        AgentEscrowV2 escrow;
    }

    function run() external virtual returns (Deployed memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        address treasury = vm.envOr("TREASURY", owner);
        address stakingRecipient = vm.envOr("STAKING_RECIPIENT", treasury);
        address referral = vm.envOr("REFERRAL", address(0));
        address erc8004 = vm.envOr("ERC8004_REGISTRY", address(0));
        address token = vm.envOr("PAYMENT_TOKEN", BASE_USDC);
        uint16 stakingBps = uint16(vm.envOr("STAKING_BPS", uint256(5000)));
        uint16 treasuryBps = uint16(vm.envOr("TREASURY_BPS", uint256(5000)));
        uint256 escrowFeeBps = vm.envOr("ESCROW_FEE_BPS", uint256(0));

        vm.startBroadcast(pk);
        d = _deploy(deployer, treasury, stakingRecipient, referral, erc8004, token, stakingBps, treasuryBps);
        _wire(d, escrowFeeBps);
        if (owner != deployer) _transferOwnership(d, owner);
        vm.stopBroadcast();

        _print(d, owner);
        _writeJson(d, owner, treasury, token);
    }

    function _deploy(
        address owner,
        address treasury,
        address stakingRecipient,
        address referral,
        address erc8004,
        address token,
        uint16 stakingBps,
        uint16 treasuryBps
    )
        internal
        returns (Deployed memory d)
    {
        d.access = new AgentAccess();
        d.identity = new AgentIdentityV2(IAgentAccess(address(d.access)), owner, erc8004);
        d.reputation = new AgentReputationV2(owner);
        d.killSwitch = new AgentKillSwitchV2(owner);
        d.auditLog = new AgentAuditLogV2(IAgentAccess(address(d.access)), owner);
        d.feeRouter = new FeeRouter(IERC20(token), owner, treasury, stakingRecipient, referral, stakingBps, treasuryBps);
        d.escrow = new AgentEscrowV2(IAgentAccess(address(d.access)), IERC20(token), owner);
    }

    /// @dev Every cross-contract permission the stack needs. Missing any of these is the v1 failure mode.
    function _wire(Deployed memory d, uint256 escrowFeeBps) internal {
        d.reputation.authorizeProtocol(address(d.escrow));
        d.auditLog.authorizeProtocol(address(d.escrow));
        d.killSwitch.authorizeProtocol(address(d.escrow));
        d.feeRouter.authorizeProtocol(address(d.escrow));
        d.escrow.setModules(address(d.reputation), address(d.auditLog), address(d.killSwitch), address(d.feeRouter));
        if (escrowFeeBps > 0) d.escrow.setFeeBps(escrowFeeBps);
    }

    function _transferOwnership(Deployed memory d, address owner) internal {
        d.identity.transferOwnership(owner);
        d.reputation.transferOwnership(owner);
        d.killSwitch.transferOwnership(owner);
        d.auditLog.transferOwnership(owner);
        d.feeRouter.transferOwnership(owner);
        d.escrow.transferOwnership(owner);
    }

    function _print(Deployed memory d, address owner) internal pure {
        console.log("chain owner:", owner);
        console.log("AgentAccess       :", address(d.access));
        console.log("AgentIdentityV2   :", address(d.identity));
        console.log("AgentReputationV2 :", address(d.reputation));
        console.log("AgentKillSwitchV2 :", address(d.killSwitch));
        console.log("AgentAuditLogV2   :", address(d.auditLog));
        console.log("FeeRouter         :", address(d.feeRouter));
        console.log("AgentEscrowV2     :", address(d.escrow));
    }

    function _writeJson(Deployed memory d, address owner, address treasury, address token) internal {
        string memory key = "v2";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "owner", owner);
        vm.serializeAddress(key, "treasury", treasury);
        vm.serializeAddress(key, "paymentToken", token);
        vm.serializeAddress(key, "AgentAccess", address(d.access));
        vm.serializeAddress(key, "AgentIdentityV2", address(d.identity));
        vm.serializeAddress(key, "AgentReputationV2", address(d.reputation));
        vm.serializeAddress(key, "AgentKillSwitchV2", address(d.killSwitch));
        vm.serializeAddress(key, "AgentAuditLogV2", address(d.auditLog));
        vm.serializeAddress(key, "FeeRouter", address(d.feeRouter));
        string memory json = vm.serializeAddress(key, "AgentEscrowV2", address(d.escrow));
        string memory path =
            vm.envOr("DEPLOY_JSON_PATH", string.concat("deployments/v2-", vm.toString(block.chainid), ".json"));
        vm.writeJson(json, path);
        console.log("wrote", path);
    }
}
