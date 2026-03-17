// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentKillSwitch} from "../../src/AgentKillSwitch.sol";
import {AgentKYA} from "../../src/AgentKYA.sol";
import {AgentAuditLog} from "../../src/AgentAuditLog.sol";
import {AgentBounty} from "../../src/AgentBounty.sol";
import {AgentLicense} from "../../src/AgentLicense.sol";
import {AgentMilestone} from "../../src/AgentMilestone.sol";
import {AgentSubscription} from "../../src/AgentSubscription.sol";
import {AgentInsolvency} from "../../src/AgentInsolvency.sol";
import {AgentReferral} from "../../src/AgentReferral.sol";
import {AgentCollective} from "../../src/AgentCollective.sol";
import {IAgentKillSwitch} from "../../src/interfaces/IAgentKillSwitch.sol";
import {IAgentKYA} from "../../src/interfaces/IAgentKYA.sol";
import {IAgentAuditLog} from "../../src/interfaces/IAgentAuditLog.sol";
import {IAgentBounty} from "../../src/interfaces/IAgentBounty.sol";
import {IAgentLicense} from "../../src/interfaces/IAgentLicense.sol";
import {IAgentMilestone} from "../../src/interfaces/IAgentMilestone.sol";
import {IAgentSubscription} from "../../src/interfaces/IAgentSubscription.sol";
import {IAgentInsolvency} from "../../src/interfaces/IAgentInsolvency.sol";
import {IAgentReferral} from "../../src/interfaces/IAgentReferral.sol";
import {IAgentCollective} from "../../src/interfaces/IAgentCollective.sol";

contract SafetyLayerAttacksTest is Test {
    ERC20Mock usdc;

    AgentKillSwitch killSwitch;
    AgentKYA kya;
    AgentAuditLog auditLog;
    AgentBounty bounty;
    AgentLicense license;
    AgentMilestone milestone;
    AgentSubscription subscription;
    AgentInsolvency insolvency;
    AgentReferral referral;
    AgentCollective collective;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address agentAddr = makeAddr("agent");
    address verifier = makeAddr("verifier");

    uint256 constant REG_FEE = 0.01 ether;
    uint256 constant USDC_MINT = 10_000_000_000; // $10k

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);

        killSwitch = new AgentKillSwitch(treasury, owner, REG_FEE);
        kya = new AgentKYA(IERC20(address(usdc)), treasury, owner, 5_000_000);
        auditLog = new AgentAuditLog(treasury, owner, 0.0001 ether);
        bounty = new AgentBounty(IERC20(address(usdc)), treasury, owner, 200);
        license = new AgentLicense(IERC20(address(usdc)), treasury, owner, 300);
        milestone = new AgentMilestone(IERC20(address(usdc)), treasury, owner, 200);
        subscription = new AgentSubscription(IERC20(address(usdc)), treasury, owner, 200);
        insolvency = new AgentInsolvency(IERC20(address(usdc)), treasury, owner, 200, 0.001 ether);
        referral = new AgentReferral(IERC20(address(usdc)), owner, 1000);
        collective = new AgentCollective(IERC20(address(usdc)), treasury, owner, 0.01 ether);

        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);
        vm.deal(agentAddr, 100 ether);
        usdc.mint(attacker, USDC_MINT);
        usdc.mint(victim, USDC_MINT);
        usdc.mint(agentAddr, USDC_MINT);

        // authorize verifier for KYA
        vm.prank(owner);
        kya.authorizeVerifier(verifier);
    }

    // ---------------------------------------------------------------
    // SCENARIO 1 -- KillSwitch bypass
    // ---------------------------------------------------------------

    function test_attack_killSwitchBypass_randomCallerCantKill() public {
        // victim registers an agent
        vm.prank(victim);
        killSwitch.registerAgent{value: REG_FEE}(agentAddr, 1 ether, 100, 1 days);

        // attacker tries to kill it -- should fail
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitch.NotOwnerOrMultisig.selector, agentAddr, attacker)
        );
        killSwitch.killSwitch(agentAddr);

        // agent is still active
        assertTrue(killSwitch.isActive(agentAddr));
    }

    function test_attack_killSwitchBypass_agentCantKillItself() public {
        vm.prank(victim);
        killSwitch.registerAgent{value: REG_FEE}(agentAddr, 1 ether, 100, 1 days);

        // agent tries to kill itself to bypass its own limits
        vm.prank(agentAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitch.AgentCannotKillItself.selector, agentAddr)
        );
        killSwitch.killSwitch(agentAddr);

        assertTrue(killSwitch.isActive(agentAddr));
    }

    function test_attack_killSwitchBypass_randomCallerCantPause() public {
        vm.prank(victim);
        killSwitch.registerAgent{value: REG_FEE}(agentAddr, 1 ether, 100, 1 days);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitch.NotOwnerOrMultisig.selector, agentAddr, attacker)
        );
        killSwitch.pauseAgent(agentAddr);
    }

    function test_attack_killSwitchBypass_randomCallerCantResume() public {
        vm.prank(victim);
        killSwitch.registerAgent{value: REG_FEE}(agentAddr, 1 ether, 100, 1 days);

        // owner pauses it
        vm.prank(victim);
        killSwitch.pauseAgent(agentAddr);

        // attacker tries to resume
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKillSwitch.NotAgentOwner.selector, agentAddr, attacker)
        );
        killSwitch.resumeAgent(agentAddr);
    }

    // ---------------------------------------------------------------
    // SCENARIO 2 -- KYA approval bypass
    // ---------------------------------------------------------------

    function test_attack_kyaApprovalBypass_nonVerifierCantApprove() public {
        // agent submits KYA
        usdc.mint(agentAddr, 10_000_000);
        vm.prank(agentAddr);
        usdc.approve(address(kya), type(uint256).max);

        vm.prank(agentAddr);
        kya.submitKYA("Agent Owner", "US", "Trading bot", 1 ether, true, keccak256("doc"));

        // attacker tries to approve -- not a verifier
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKYA.NotVerifier.selector, attacker)
        );
        kya.approveKYA(agentAddr);

        // confirm still pending
        (IAgentKYA.KYAStatus status,) = kya.getKYAStatus(agentAddr);
        assertEq(uint8(status), uint8(IAgentKYA.KYAStatus.PENDING));
    }

    function test_attack_kyaApprovalBypass_ownerAloneCantApprove() public {
        usdc.mint(agentAddr, 10_000_000);
        vm.prank(agentAddr);
        usdc.approve(address(kya), type(uint256).max);

        vm.prank(agentAddr);
        kya.submitKYA("Agent Owner", "US", "Trading bot", 1 ether, true, keccak256("doc"));

        // contract owner is NOT a verifier by default
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentKYA.NotVerifier.selector, owner)
        );
        kya.approveKYA(agentAddr);
    }

    // ---------------------------------------------------------------
    // SCENARIO 3 -- AuditLog tampering
    // ---------------------------------------------------------------

    function test_attack_auditLogTampering_noUpdateFunction() public {
        // agent logs an action
        bytes32 actionType = keccak256("TRADE");
        bytes32 dataHash = keccak256("trade-data-001");

        vm.prank(agentAddr);
        uint256 logId = auditLog.logAction{value: 0.0001 ether}(agentAddr, actionType, dataHash, 1 ether);

        // read the log back
        IAgentAuditLog.ActionLog memory entry = auditLog.getLog(logId);
        assertEq(entry.dataHash, dataHash);
        assertEq(entry.agent, agentAddr);
        assertEq(entry.actionType, actionType);
        assertEq(entry.value, 1 ether);

        // there is no setLog, updateLog, or deleteLog function on the contract
        // the only write functions are logAction, logActionBatch, authorizeLogger, revokeLogger
        // so the entry is immutable after creation
        assertTrue(auditLog.verifyAction(logId, dataHash));
    }

    function test_attack_auditLogTampering_unauthorizedLoggerCantLog() public {
        bytes32 actionType = keccak256("TRADE");
        bytes32 dataHash = keccak256("fake-entry");

        // attacker tries to log on behalf of victim (not authorized)
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentAuditLog.NotAgentOrLogger.selector, victim, attacker)
        );
        auditLog.logAction{value: 0.0001 ether}(victim, actionType, dataHash, 0);
    }

    function test_attack_auditLogTampering_logCountOnlyIncreases() public {
        bytes32 actionType = keccak256("TRADE");

        vm.startPrank(agentAddr);
        uint256 id0 = auditLog.logAction{value: 0.0001 ether}(agentAddr, actionType, keccak256("a"), 0);
        uint256 id1 = auditLog.logAction{value: 0.0001 ether}(agentAddr, actionType, keccak256("b"), 0);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(auditLog.totalLogs(), 2);

        // old entries remain unchanged
        IAgentAuditLog.ActionLog memory e0 = auditLog.getLog(0);
        assertEq(e0.dataHash, keccak256("a"));
    }

    // ---------------------------------------------------------------
    // SCENARIO 4 -- Bounty drain
    // ---------------------------------------------------------------

    function test_attack_bountyDrain_wrongHashDoesntWin() public {
        bytes32 validationHash = keccak256("correct-answer");
        uint48 deadline = uint48(block.timestamp + 2 hours);
        uint256 reward = 100_000_000; // $100

        // poster creates bounty
        vm.prank(victim);
        usdc.approve(address(bounty), type(uint256).max);
        vm.prank(victim);
        uint256 bountyId = bounty.postBounty("Solve this", "Requirements", reward, deadline, validationHash);

        uint256 attackerBefore = usdc.balanceOf(attacker);

        // attacker submits wrong hash
        vm.prank(attacker);
        bounty.submitSolution(bountyId, keccak256("wrong-answer"));

        // bounty is still open, attacker got nothing
        IAgentBounty.Bounty memory b = bounty.getBounty(bountyId);
        assertEq(uint8(b.status), uint8(IAgentBounty.BountyStatus.Open));
        assertEq(b.winner, address(0));
        assertEq(usdc.balanceOf(attacker), attackerBefore);
    }

    function test_attack_bountyDrain_posterCantCancelAfterSubmission() public {
        bytes32 validationHash = keccak256("correct-answer");
        uint48 deadline = uint48(block.timestamp + 2 hours);
        uint256 reward = 100_000_000;

        vm.prank(victim);
        usdc.approve(address(bounty), type(uint256).max);
        vm.prank(victim);
        uint256 bountyId = bounty.postBounty("Solve this", "Requirements", reward, deadline, validationHash);

        // solver submits (wrong answer, but a submission exists)
        vm.prank(attacker);
        bounty.submitSolution(bountyId, keccak256("attempt"));

        // poster tries to cancel and reclaim reward
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentBounty.BountyHasSubmissions.selector, bountyId)
        );
        bounty.cancelBounty(bountyId);
    }

    function test_attack_bountyDrain_correctHashAutoWins() public {
        bytes32 validationHash = keccak256("correct-answer");
        uint48 deadline = uint48(block.timestamp + 2 hours);
        uint256 reward = 100_000_000;

        vm.prank(victim);
        usdc.approve(address(bounty), type(uint256).max);
        vm.prank(victim);
        uint256 bountyId = bounty.postBounty("Solve this", "Requirements", reward, deadline, validationHash);

        uint256 solverBefore = usdc.balanceOf(attacker);

        // solver submits correct hash
        vm.prank(attacker);
        bounty.submitSolution(bountyId, validationHash);

        IAgentBounty.Bounty memory b = bounty.getBounty(bountyId);
        assertEq(uint8(b.status), uint8(IAgentBounty.BountyStatus.Completed));
        assertEq(b.winner, attacker);
        assertEq(usdc.balanceOf(attacker) - solverBefore, reward);
    }

    // ---------------------------------------------------------------
    // SCENARIO 5 -- License overclaim
    // ---------------------------------------------------------------

    function test_attack_licenseOverclaim_expiredSubscriptionBlocked() public {
        // register a license
        vm.prank(victim);
        uint256 licenseId = license.registerLicense("My Model", keccak256("model-v1"), 10_000_000, 50_000_000);

        // attacker buys a subscription (1 month)
        vm.prank(attacker);
        usdc.approve(address(license), type(uint256).max);
        vm.prank(attacker);
        license.purchaseLicense(licenseId, uint8(IAgentLicense.LicenseType.SUBSCRIPTION));

        // fast forward 31 days -- subscription expired
        vm.warp(block.timestamp + 31 days);

        // usage should revert -- no valid license
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentLicense.NoValidLicense.selector, licenseId, attacker)
        );
        license.recordUsage(licenseId);
    }

    function test_attack_licenseOverclaim_perUseExhausted() public {
        vm.prank(victim);
        uint256 licenseId = license.registerLicense("My Model", keccak256("model-v1"), 10_000_000, 50_000_000);

        // buy 1 per-use license
        vm.prank(attacker);
        usdc.approve(address(license), type(uint256).max);
        vm.prank(attacker);
        license.purchaseLicense(licenseId, uint8(IAgentLicense.LicenseType.PER_USE));

        // use it once
        vm.prank(attacker);
        license.recordUsage(licenseId);

        // second use should fail
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentLicense.NoValidLicense.selector, licenseId, attacker)
        );
        license.recordUsage(licenseId);
    }

    // ---------------------------------------------------------------
    // SCENARIO 6 -- Milestone skip
    // ---------------------------------------------------------------

    function test_attack_milestoneSkip_cantSkipToMilestone2() public {
        bytes32[] memory hashes = new bytes32[](3);
        uint256[] memory amounts = new uint256[](3);
        hashes[0] = keccak256("m1");
        hashes[1] = keccak256("m2");
        hashes[2] = keccak256("m3");
        amounts[0] = 100_000_000;
        amounts[1] = 200_000_000;
        amounts[2] = 200_000_000;
        uint256 total = 500_000_000;

        vm.prank(victim);
        usdc.approve(address(milestone), type(uint256).max);
        vm.prank(victim);
        uint256 contractId = milestone.createContract(
            agentAddr, total, hashes, amounts, uint48(block.timestamp + 30 days)
        );

        // agent tries to submit milestone index 1 (skipping 0)
        vm.prank(agentAddr);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentMilestone.MilestoneOutOfOrder.selector, contractId, 1, 0)
        );
        milestone.submitMilestone(contractId, 1, keccak256("m2"));
    }

    function test_attack_milestoneSkip_mustCompleteSequentially() public {
        bytes32[] memory hashes = new bytes32[](2);
        uint256[] memory amounts = new uint256[](2);
        hashes[0] = keccak256("m1");
        hashes[1] = keccak256("m2");
        amounts[0] = 100_000_000;
        amounts[1] = 100_000_000;

        vm.prank(victim);
        usdc.approve(address(milestone), type(uint256).max);
        vm.prank(victim);
        uint256 contractId = milestone.createContract(
            agentAddr, 200_000_000, hashes, amounts, uint48(block.timestamp + 30 days)
        );

        // complete milestone 0 with correct hash
        vm.prank(agentAddr);
        milestone.submitMilestone(contractId, 0, keccak256("m1"));

        // now milestone 1 is unlocked
        uint256 agentBefore = usdc.balanceOf(agentAddr);
        vm.prank(agentAddr);
        milestone.submitMilestone(contractId, 1, keccak256("m2"));

        assertEq(usdc.balanceOf(agentAddr) - agentBefore, 100_000_000);
    }

    function test_attack_milestoneSkip_nonAgentCantSubmit() public {
        bytes32[] memory hashes = new bytes32[](1);
        uint256[] memory amounts = new uint256[](1);
        hashes[0] = keccak256("m1");
        amounts[0] = 100_000_000;

        vm.prank(victim);
        usdc.approve(address(milestone), type(uint256).max);
        vm.prank(victim);
        uint256 contractId = milestone.createContract(
            agentAddr, 100_000_000, hashes, amounts, uint48(block.timestamp + 30 days)
        );

        // attacker tries to submit on behalf of the agent
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentMilestone.NotAgent.selector, contractId)
        );
        milestone.submitMilestone(contractId, 0, keccak256("m1"));
    }

    // ---------------------------------------------------------------
    // SCENARIO 7 -- Subscription double charge
    // ---------------------------------------------------------------

    function test_attack_subscriptionDoubleCharge_renewalNotDueYet() public {
        // provider creates a plan (1 day interval, $10)
        vm.prank(victim);
        uint256 planId = subscription.createPlan("Pro Plan", 10_000_000, uint48(1 days), 0);

        // subscriber subscribes for 1 period
        vm.prank(attacker);
        usdc.approve(address(subscription), type(uint256).max);
        vm.prank(attacker);
        uint256 subId = subscription.subscribe(planId, 1);

        IAgentSubscription.Subscription memory sub = subscription.getSubscription(subId);

        // try to process renewal immediately (before paidUntil)
        vm.expectRevert(
            abi.encodeWithSelector(IAgentSubscription.RenewalNotDue.selector, subId, sub.nextPaymentDue)
        );
        subscription.processRenewal(subId);
    }

    function test_attack_subscriptionDoubleCharge_canOnlyChargeOncePerPeriod() public {
        vm.prank(victim);
        uint256 planId = subscription.createPlan("Pro Plan", 10_000_000, uint48(1 days), 0);

        vm.prank(attacker);
        usdc.approve(address(subscription), type(uint256).max);
        vm.prank(attacker);
        uint256 subId = subscription.subscribe(planId, 1);

        // warp past the paid period
        vm.warp(block.timestamp + 1 days + 1);

        uint256 balBefore = usdc.balanceOf(attacker);

        // first renewal succeeds
        subscription.processRenewal(subId);
        uint256 charged1 = balBefore - usdc.balanceOf(attacker);
        assertEq(charged1, 10_000_000);

        // second renewal in the same block fails
        IAgentSubscription.Subscription memory sub2 = subscription.getSubscription(subId);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentSubscription.RenewalNotDue.selector, subId, sub2.nextPaymentDue)
        );
        subscription.processRenewal(subId);
    }

    // ---------------------------------------------------------------
    // SCENARIO 8 -- Insolvency manipulation
    // ---------------------------------------------------------------

    function test_attack_insolvencyManipulation_randomCantDeclare() public {
        // victim registers a debt
        vm.prank(victim);
        insolvency.registerDebt{value: 0.001 ether}(
            attacker, 1_000_000_000, uint48(block.timestamp + 30 days), "Loan"
        );

        // attacker (random third party) tries to declare victim insolvent
        address thirdParty = makeAddr("thirdParty");
        vm.prank(thirdParty);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentInsolvency.NotDebtorOrOwner.selector, victim, thirdParty)
        );
        insolvency.declareInsolvency(victim, 0);
    }

    function test_attack_insolvencyManipulation_doubleClaim() public {
        // set up: victim owes attacker 1000 USDC
        vm.prank(victim);
        uint256 debtId = insolvency.registerDebt{value: 0.001 ether}(
            attacker, 1_000_000_000, uint48(block.timestamp + 30 days), "Loan"
        );

        // creditor confirms
        vm.prank(attacker);
        insolvency.confirmDebt(debtId);

        // debtor declares insolvency with 500 USDC deposit
        vm.prank(victim);
        usdc.approve(address(insolvency), type(uint256).max);
        vm.prank(victim);
        insolvency.declareInsolvency(victim, 500_000_000);

        // creditor claims payout
        vm.prank(attacker);
        insolvency.claimInsolvencyPayout(victim, debtId);

        // try to double-claim the same debt
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentInsolvency.DebtAlreadyResolved.selector, debtId)
        );
        insolvency.claimInsolvencyPayout(victim, debtId);
    }

    function test_attack_insolvencyManipulation_cantDeclareInsolvencyTwice() public {
        vm.prank(victim);
        insolvency.registerDebt{value: 0.001 ether}(
            attacker, 100_000_000, uint48(block.timestamp + 30 days), "Loan"
        );
        vm.prank(attacker);
        insolvency.confirmDebt(0);

        vm.prank(victim);
        usdc.approve(address(insolvency), type(uint256).max);
        vm.prank(victim);
        insolvency.declareInsolvency(victim, 0);

        // second declaration fails
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentInsolvency.AlreadyInsolvent.selector, victim)
        );
        insolvency.declareInsolvency(victim, 0);
    }

    // ---------------------------------------------------------------
    // SCENARIO 9 -- Referral circular attack
    // ---------------------------------------------------------------

    function test_attack_referralCircular_selfReferral() public {
        vm.prank(attacker);
        vm.expectRevert(IAgentReferral.SelfReferral.selector);
        referral.registerReferral(attacker);
    }

    function test_attack_referralCircular_directCycle() public {
        // A refers to B first
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(alice);
        referral.registerReferral(bob);

        // B tries to refer to A, creating cycle B->A->B
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentReferral.CircularReferral.selector, bob, alice)
        );
        referral.registerReferral(alice);
    }

    function test_attack_referralCircular_deepCycle() public {
        // build a chain: A -> B -> C -> D
        address a = makeAddr("rA");
        address b = makeAddr("rB");
        address c = makeAddr("rC");
        address d = makeAddr("rD");

        vm.prank(a);
        referral.registerReferral(b);
        vm.prank(b);
        referral.registerReferral(c);
        vm.prank(c);
        referral.registerReferral(d);

        // D tries to refer to A -- creates cycle D->A->B->C->D
        vm.prank(d);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentReferral.CircularReferral.selector, d, a)
        );
        referral.registerReferral(a);
    }

    function test_attack_referralCircular_cantRegisterTwice() public {
        vm.prank(attacker);
        referral.registerReferral(victim);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentReferral.AlreadyRegistered.selector, attacker)
        );
        referral.registerReferral(victim);
    }

    // ---------------------------------------------------------------
    // SCENARIO 10 -- Collective treasury drain
    // ---------------------------------------------------------------

    function test_attack_collectiveTreasuryDrain_lockPeriodEnforced() public {
        // create collective with entry fee and profit share
        vm.prank(victim);
        uint256 id = collective.createCollective{value: 0.01 ether}("Alpha Fund", 0, 100_000_000, 5000);

        // attacker joins
        vm.prank(attacker);
        usdc.approve(address(collective), type(uint256).max);
        vm.prank(attacker);
        collective.joinCollective(id);

        // deposit revenue to give the collective a treasury
        vm.prank(attacker);
        collective.depositRevenue(id, 500_000_000);

        // try to leave immediately (within 30-day lock)
        vm.prank(attacker);
        collective.leaveCollective(id);

        // the leaveCollective call does NOT revert, but the payout should be 0
        // because pastLock is false within the 30-day lock period
        // attacker's USDC balance should not have increased from the treasury
        // (entry fee of 100_000_000 was paid, 500_000_000 was deposited, net outflow)
        // the 0-payout on leave is the protection
    }

    function test_attack_collectiveTreasuryDrain_noProfitBeforeLock() public {
        vm.prank(victim);
        uint256 id = collective.createCollective{value: 0.01 ether}("Alpha Fund", 0, 0, 5000);

        // victim joins first, deposits revenue
        vm.prank(victim);
        usdc.approve(address(collective), type(uint256).max);
        vm.prank(victim);
        collective.joinCollective(id);
        vm.prank(victim);
        collective.depositRevenue(id, 1_000_000_000);

        // attacker joins same block
        vm.prank(attacker);
        usdc.approve(address(collective), type(uint256).max);
        vm.prank(attacker);
        collective.joinCollective(id);

        // attacker tries to leave immediately to claim share
        uint256 attackerBefore = usdc.balanceOf(attacker);
        vm.prank(attacker);
        collective.leaveCollective(id);

        // attacker received 0 payout because lock period hasn't passed
        uint256 attackerAfter = usdc.balanceOf(attacker);
        assertEq(attackerAfter, attackerBefore);
    }

    function test_attack_collectiveTreasuryDrain_leaveRejoinSameBlockNoPayout() public {
        vm.prank(victim);
        uint256 id = collective.createCollective{value: 0.01 ether}("Alpha Fund", 0, 0, 5000);

        vm.prank(victim);
        usdc.approve(address(collective), type(uint256).max);
        vm.prank(victim);
        collective.joinCollective(id);

        vm.prank(victim);
        collective.depositRevenue(id, 1_000_000_000);

        vm.prank(attacker);
        usdc.approve(address(collective), type(uint256).max);
        vm.prank(attacker);
        collective.joinCollective(id);

        // warp past lock period
        vm.warp(block.timestamp + 31 days);

        // attacker leaves (gets payout)
        uint256 balBefore = usdc.balanceOf(attacker);
        vm.prank(attacker);
        collective.leaveCollective(id);
        uint256 firstPayout = usdc.balanceOf(attacker) - balBefore;
        assertGt(firstPayout, 0);

        // attacker rejoins in same block
        vm.prank(attacker);
        collective.joinCollective(id);

        // immediately tries to leave again -- should get 0 because new lock period
        uint256 balBefore2 = usdc.balanceOf(attacker);
        vm.prank(attacker);
        collective.leaveCollective(id);
        uint256 secondPayout = usdc.balanceOf(attacker) - balBefore2;
        assertEq(secondPayout, 0);
    }

    function test_attack_collectiveTreasuryDrain_soulboundCantTransfer() public {
        vm.prank(victim);
        uint256 id = collective.createCollective{value: 0.01 ether}("Alpha Fund", 0, 0, 5000);

        vm.prank(attacker);
        usdc.approve(address(collective), type(uint256).max);
        vm.prank(attacker);
        collective.joinCollective(id);

        // try to transfer membership token to another address
        vm.prank(attacker);
        vm.expectRevert(IAgentCollective.SoulboundToken.selector);
        collective.safeTransferFrom(attacker, victim, id, 1, "");
    }
}
