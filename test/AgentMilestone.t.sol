// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentMilestone} from "../src/AgentMilestone.sol";
import {IAgentMilestone} from "../src/interfaces/IAgentMilestone.sol";

contract AgentMilestoneTest is Test {
    ERC20Mock usdc;
    AgentMilestone milestone;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address client = makeAddr("client");
    address agent = makeAddr("agent");

    uint256 constant FEE_BPS = 50; // 0.5%
    uint256 constant BPS = 10_000;
    uint256 constant TOTAL = 300_000_000; // $300
    bytes32 constant HASH1 = keccak256("milestone-1");
    bytes32 constant HASH2 = keccak256("milestone-2");
    bytes32 constant HASH3 = keccak256("milestone-3");

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        milestone = new AgentMilestone(IERC20(address(usdc)), treasury, owner, FEE_BPS);

        usdc.mint(client, 10_000_000_000);
        vm.prank(client);
        usdc.approve(address(milestone), type(uint256).max);
    }

    function _deadline() internal view returns (uint48) {
        return uint48(block.timestamp + 7 days);
    }

    function _createDefault() internal returns (uint256) {
        bytes32[] memory hashes = new bytes32[](3);
        uint256[] memory amounts = new uint256[](3);
        hashes[0] = HASH1; hashes[1] = HASH2; hashes[2] = HASH3;
        amounts[0] = 100_000_000; amounts[1] = 100_000_000; amounts[2] = 100_000_000;

        vm.prank(client);
        return milestone.createContract(agent, TOTAL, hashes, amounts, _deadline());
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(milestone.treasury(), treasury);
        assertEq(milestone.platformFeeBps(), FEE_BPS);
    }

    // ─── Create ─────────────────────────────────────────────────────────

    function test_createContract() public {
        uint256 id = _createDefault();
        assertEq(id, 0);

        IAgentMilestone.MilestoneContract memory c = milestone.getContract(id);
        assertEq(c.client, client);
        assertEq(c.agent, agent);
        assertEq(c.totalAmount, TOTAL);
        assertEq(c.milestoneCount, 3);
        assertEq(c.nextMilestone, 0);
        assertTrue(c.active);
    }

    function test_createTakesFeeAndTotal() public {
        uint256 fee = TOTAL * FEE_BPS / BPS;
        uint256 clientBefore = usdc.balanceOf(client);
        _createDefault();
        assertEq(clientBefore - usdc.balanceOf(client), TOTAL + fee);
    }

    function test_revert_createAmountMismatch() public {
        bytes32[] memory h = new bytes32[](2);
        uint256[] memory a = new uint256[](2);
        h[0] = HASH1; h[1] = HASH2;
        a[0] = 100_000_000; a[1] = 100_000_000; // sum = 200, not 300

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.AmountMismatch.selector, 200_000_000, TOTAL));
        milestone.createContract(agent, TOTAL, h, a, _deadline());
    }

    function test_revert_createEmptyMilestones() public {
        bytes32[] memory h = new bytes32[](0);
        uint256[] memory a = new uint256[](0);

        vm.prank(client);
        vm.expectRevert(IAgentMilestone.EmptyMilestones.selector);
        milestone.createContract(agent, TOTAL, h, a, _deadline());
    }

    // ─── Submit Milestone ───────────────────────────────────────────────

    function test_submitAutoValidates() public {
        uint256 id = _createDefault();

        uint256 agentBefore = usdc.balanceOf(agent);
        vm.prank(agent);
        milestone.submitMilestone(id, 0, HASH1); // matches

        uint256 paid = usdc.balanceOf(agent) - agentBefore + milestone.getClaimable(agent);
        assertEq(paid, 100_000_000);
        assertEq(milestone.getContract(id).nextMilestone, 1);
    }

    function test_submitWrongHashPending() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        milestone.submitMilestone(id, 0, keccak256("wrong"));

        IAgentMilestone.Milestone memory m = milestone.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(IAgentMilestone.MilestoneStatus.Submitted));
        // not auto-approved — needs manual
    }

    function test_revert_submitOutOfOrder() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.MilestoneOutOfOrder.selector, id, 1, 0));
        milestone.submitMilestone(id, 1, HASH2); // skip milestone 0
    }

    function test_revert_submitNotAgent() public {
        uint256 id = _createDefault();

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.NotAgent.selector, id));
        milestone.submitMilestone(id, 0, HASH1);
    }

    function test_revert_submitExpired() public {
        uint256 id = _createDefault();
        vm.warp(block.timestamp + 8 days);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.ContractExpiredError.selector, id));
        milestone.submitMilestone(id, 0, HASH1);
    }

    function test_fullContractCompletion() public {
        uint256 id = _createDefault();

        vm.startPrank(agent);
        milestone.submitMilestone(id, 0, HASH1);
        milestone.submitMilestone(id, 1, HASH2);
        milestone.submitMilestone(id, 2, HASH3);
        vm.stopPrank();

        IAgentMilestone.MilestoneContract memory c = milestone.getContract(id);
        assertFalse(c.active); // completed
        assertEq(c.released, TOTAL);
    }

    // ─── Manual Approve ─────────────────────────────────────────────────

    function test_manualApprove() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        milestone.submitMilestone(id, 0, keccak256("wrong")); // wrong hash

        vm.prank(client);
        milestone.approveMilestone(id, 0);

        assertEq(uint8(milestone.getMilestone(id, 0).status), uint8(IAgentMilestone.MilestoneStatus.Approved));
        assertEq(milestone.getContract(id).nextMilestone, 1);
    }

    function test_revert_approveNotClient() public {
        uint256 id = _createDefault();
        vm.prank(agent);
        milestone.submitMilestone(id, 0, keccak256("x"));

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.NotClient.selector, id));
        milestone.approveMilestone(id, 0);
    }

    // ─── Dispute ────────────────────────────────────────────────────────

    function test_disputeAndResolveApprove() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        milestone.submitMilestone(id, 0, keccak256("bad"));

        vm.prank(client);
        milestone.disputeMilestone(id, 0);

        vm.prank(owner);
        milestone.resolveDispute(id, 0, true);

        assertEq(uint8(milestone.getMilestone(id, 0).status), uint8(IAgentMilestone.MilestoneStatus.Approved));
    }

    function test_disputeAndResolveReject() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        milestone.submitMilestone(id, 0, keccak256("bad"));

        vm.prank(client);
        milestone.disputeMilestone(id, 0);

        vm.prank(owner);
        milestone.resolveDispute(id, 0, false);

        // milestone reset to Pending — agent can resubmit
        assertEq(uint8(milestone.getMilestone(id, 0).status), uint8(IAgentMilestone.MilestoneStatus.Pending));
        assertEq(milestone.getContract(id).nextMilestone, 0);
    }

    // ─── Cancel ─────────────────────────────────────────────────────────

    function test_cancelBeforeDelivery() public {
        uint256 id = _createDefault();

        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        milestone.cancelContract(id);

        assertEq(usdc.balanceOf(client) - clientBefore, TOTAL);
        assertFalse(milestone.getContract(id).active);
    }

    function test_revert_cancelAfterDelivery() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        milestone.submitMilestone(id, 0, HASH1); // delivers milestone 0

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.MilestonesAlreadyDelivered.selector, id));
        milestone.cancelContract(id);
    }

    // ─── Expire ─────────────────────────────────────────────────────────

    function test_expireContract() public {
        uint256 id = _createDefault();

        vm.prank(agent);
        milestone.submitMilestone(id, 0, HASH1); // delivers 1 of 3

        vm.warp(block.timestamp + 8 days);

        uint256 clientBefore = usdc.balanceOf(client);
        milestone.expireContract(id);

        uint256 remaining = TOTAL - 100_000_000; // 2 milestones unreleased
        assertEq(usdc.balanceOf(client) - clientBefore, remaining);
    }

    function test_revert_expireBeforeDeadline() public {
        uint256 id = _createDefault();
        vm.expectRevert(IAgentMilestone.InvalidDeadline.selector);
        milestone.expireContract(id);
    }

    // ─── Fee + Admin ────────────────────────────────────────────────────

    function test_collectFees() public {
        _createDefault();
        uint256 fee = TOTAL * FEE_BPS / BPS;
        uint256 before_ = usdc.balanceOf(treasury);
        milestone.collectFees();
        assertEq(usdc.balanceOf(treasury) - before_, fee);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentMilestone.NoFeesToCollect.selector);
        milestone.collectFees();
    }

    function test_setFee() public {
        vm.prank(owner);
        milestone.setPlatformFeeBps(100);
        assertEq(milestone.platformFeeBps(), 100);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        milestone.setTreasury(newT);
        assertEq(milestone.treasury(), newT);
    }

    function test_revert_getContractNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentMilestone.ContractNotFound.selector, 999));
        milestone.getContract(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_milestoneAmountSum(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 1_000_000, 500_000_000);
        a2 = bound(a2, 1_000_000, 500_000_000);
        uint256 total = a1 + a2;

        bytes32[] memory h = new bytes32[](2);
        uint256[] memory a = new uint256[](2);
        h[0] = HASH1; h[1] = HASH2;
        a[0] = a1; a[1] = a2;

        uint256 fee = total * FEE_BPS / BPS;
        usdc.mint(client, total + fee);

        vm.prank(client);
        uint256 id = milestone.createContract(agent, total, h, a, _deadline());

        assertEq(milestone.getContract(id).totalAmount, total);
    }

    function testFuzz_sequentialDelivery(uint8 count) public {
        count = uint8(bound(count, 1, 10));
        uint256 perMs = 10_000_000;
        uint256 total = perMs * count;

        bytes32[] memory h = new bytes32[](count);
        uint256[] memory a = new uint256[](count);
        for (uint i; i < count; i++) {
            h[i] = keccak256(abi.encode("ms", i));
            a[i] = perMs;
        }

        uint256 fee = total * FEE_BPS / BPS;
        usdc.mint(client, total + fee);

        vm.prank(client);
        uint256 id = milestone.createContract(agent, total, h, a, _deadline());

        vm.startPrank(agent);
        for (uint i; i < count; i++) {
            milestone.submitMilestone(id, i, h[i]);
        }
        vm.stopPrank();

        assertEq(milestone.getContract(id).released, total);
    }
}
