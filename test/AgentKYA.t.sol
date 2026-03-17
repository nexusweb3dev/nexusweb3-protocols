// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentKYA} from "../src/AgentKYA.sol";
import {IAgentKYA} from "../src/interfaces/IAgentKYA.sol";

contract AgentKYATest is Test {
    ERC20Mock usdc;
    AgentKYA kya;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address verifier = makeAddr("verifier");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address stranger = makeAddr("stranger");

    uint256 constant FEE = 10_000_000; // $10
    bytes32 constant DOC_HASH = keccak256("compliance-doc-v1");

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        kya = new AgentKYA(IERC20(address(usdc)), treasury, owner, FEE);

        vm.prank(owner);
        kya.authorizeVerifier(verifier);

        usdc.mint(agent1, 100_000_000);
        usdc.mint(agent2, 100_000_000);
        vm.prank(agent1);
        usdc.approve(address(kya), type(uint256).max);
        vm.prank(agent2);
        usdc.approve(address(kya), type(uint256).max);
    }

    function _submitDefault() internal {
        vm.prank(agent1);
        kya.submitKYA("Alice Corp", "US-DE", "Trading bot", 1_000_000, true, DOC_HASH);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(kya.treasury(), treasury);
        assertEq(kya.owner(), owner);
        assertEq(kya.verificationFee(), FEE);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentKYA.ZeroAddress.selector);
        new AgentKYA(IERC20(address(0)), treasury, owner, FEE);
    }

    // ─── Submit ─────────────────────────────────────────────────────────

    function test_submitKYA() public {
        _submitDefault();

        (IAgentKYA.KYAStatus status, uint48 ts) = kya.getKYAStatus(agent1);
        assertEq(uint8(status), uint8(IAgentKYA.KYAStatus.PENDING));
        assertEq(ts, uint48(block.timestamp));
        assertEq(kya.totalSubmissions(), 1);
        assertEq(kya.accumulatedFees(), FEE);
    }

    function test_submitKYAData() public {
        _submitDefault();
        IAgentKYA.KYAData memory d = kya.getKYAData(agent1);
        assertEq(d.ownerName, "Alice Corp");
        assertEq(d.jurisdiction, "US-DE");
        assertEq(d.documentHash, DOC_HASH);
        assertTrue(d.humanSupervised);
    }

    function test_revert_submitDuplicate() public {
        _submitDefault();
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.AlreadySubmitted.selector, agent1));
        kya.submitKYA("X", "Y", "Z", 1, true, DOC_HASH);
    }

    function test_revert_submitEmptyOwnerName() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentKYA.EmptyOwnerName.selector);
        kya.submitKYA("", "US", "Bot", 1, true, DOC_HASH);
    }

    function test_revert_submitEmptyJurisdiction() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentKYA.EmptyJurisdiction.selector);
        kya.submitKYA("Alice", "", "Bot", 1, true, DOC_HASH);
    }

    function test_revert_submitEmptyPurpose() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentKYA.EmptyPurpose.selector);
        kya.submitKYA("Alice", "US", "", 1, true, DOC_HASH);
    }

    function test_revert_submitZeroDocHash() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentKYA.InvalidDocumentHash.selector);
        kya.submitKYA("Alice", "US", "Bot", 1, true, bytes32(0));
    }

    function test_revert_submitWhenPaused() public {
        vm.prank(owner);
        kya.pause();
        vm.prank(agent1);
        vm.expectRevert();
        kya.submitKYA("Alice", "US", "Bot", 1, true, DOC_HASH);
    }

    // ─── Verify ─────────────────────────────────────────────────────────

    function test_approveKYA() public {
        _submitDefault();

        vm.prank(verifier);
        kya.approveKYA(agent1);

        assertTrue(kya.isVerified(agent1));
        (IAgentKYA.KYAStatus status,) = kya.getKYAStatus(agent1);
        assertEq(uint8(status), uint8(IAgentKYA.KYAStatus.VERIFIED));
    }

    function test_revert_approveNotVerifier() public {
        _submitDefault();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.NotVerifier.selector, stranger));
        kya.approveKYA(agent1);
    }

    function test_revert_approveNotSubmitted() public {
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.NotSubmitted.selector, agent2));
        kya.approveKYA(agent2);
    }

    function test_revert_approveTwice() public {
        _submitDefault();
        vm.prank(verifier);
        kya.approveKYA(agent1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.AlreadyVerified.selector, agent1));
        kya.approveKYA(agent1);
    }

    // ─── Revoke ─────────────────────────────────────────────────────────

    function test_revokeKYA() public {
        _submitDefault();
        vm.prank(verifier);
        kya.approveKYA(agent1);

        vm.prank(verifier);
        kya.revokeKYA(agent1, "fraud detected");

        assertFalse(kya.isVerified(agent1));
        IAgentKYA.KYAData memory d = kya.getKYAData(agent1);
        assertEq(uint8(d.status), uint8(IAgentKYA.KYAStatus.REVOKED));
        assertEq(d.revocationReason, "fraud detected");
    }

    function test_revokeByOwner() public {
        _submitDefault();
        vm.prank(owner);
        kya.revokeKYA(agent1, "owner decision");
        assertEq(uint8(kya.getKYAData(agent1).status), uint8(IAgentKYA.KYAStatus.REVOKED));
    }

    function test_revert_revokeByStranger() public {
        _submitDefault();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.NotVerifier.selector, stranger));
        kya.revokeKYA(agent1, "bad");
    }

    function test_revert_revokeTwice() public {
        _submitDefault();
        vm.prank(verifier);
        kya.revokeKYA(agent1, "first");
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.AlreadyRevoked.selector, agent1));
        kya.revokeKYA(agent1, "second");
    }

    // ─── Suspend ────────────────────────────────────────────────────────

    function test_suspendKYA() public {
        _submitDefault();
        vm.prank(verifier);
        kya.approveKYA(agent1);

        vm.prank(verifier);
        kya.suspendKYA(agent1);

        assertFalse(kya.isVerified(agent1));
        assertEq(uint8(kya.getKYAData(agent1).status), uint8(IAgentKYA.KYAStatus.SUSPENDED));
    }

    // ─── Verifier Management ────────────────────────────────────────────

    function test_authorizeVerifier() public {
        address v2 = makeAddr("v2");
        vm.prank(owner);
        kya.authorizeVerifier(v2);
        assertTrue(kya.isVerifier(v2));
    }

    function test_revokeVerifier() public {
        vm.prank(owner);
        kya.revokeVerifier(verifier);
        assertFalse(kya.isVerifier(verifier));
    }

    function test_revert_authorizeZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentKYA.ZeroAddress.selector);
        kya.authorizeVerifier(address(0));
    }

    function test_revert_authorizeDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.AlreadyVerifier.selector, verifier));
        kya.authorizeVerifier(verifier);
    }

    // ─── Fee + Admin ────────────────────────────────────────────────────

    function test_collectFees() public {
        _submitDefault();
        uint256 before_ = usdc.balanceOf(treasury);
        kya.collectFees();
        assertEq(usdc.balanceOf(treasury) - before_, FEE);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentKYA.NoFeesToCollect.selector);
        kya.collectFees();
    }

    function test_setVerificationFee() public {
        vm.prank(owner);
        kya.setVerificationFee(20_000_000);
        assertEq(kya.verificationFee(), 20_000_000);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        kya.setTreasury(newT);
        assertEq(kya.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentKYA.ZeroAddress.selector);
        kya.setTreasury(address(0));
    }

    function test_statusNoneForUnsubmitted() public view {
        (IAgentKYA.KYAStatus status, uint48 ts) = kya.getKYAStatus(stranger);
        assertEq(uint8(status), uint8(IAgentKYA.KYAStatus.NONE));
        assertEq(ts, 0);
    }

    function test_revert_getDataNotSubmitted() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentKYA.NotSubmitted.selector, stranger));
        kya.getKYAData(stranger);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_submitAndVerify(bytes32 docHash) public {
        vm.assume(docHash != bytes32(0));

        vm.prank(agent1);
        kya.submitKYA("Fuzz Corp", "EU", "Fuzz bot", 999, false, docHash);

        vm.prank(verifier);
        kya.approveKYA(agent1);

        assertTrue(kya.isVerified(agent1));
        assertEq(kya.getKYAData(agent1).documentHash, docHash);
    }
}
