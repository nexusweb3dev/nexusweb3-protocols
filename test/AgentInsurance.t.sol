// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentInsurance} from "../src/AgentInsurance.sol";
import {IAgentInsurance} from "../src/interfaces/IAgentInsurance.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

contract AgentInsuranceTest is Test {
    ERC20Mock usdc;
    MockAToken aUsdc;
    MockAavePool aavePool;
    AgentInsurance insurance;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address agent3 = makeAddr("agent3");

    uint256 constant PREMIUM = 10_000_000; // $10 USDC
    uint256 constant COVERAGE_MULT = 10;
    uint256 constant FEE_BPS = 1500; // 15%
    uint256 constant BPS = 10_000;
    uint256 constant MONTH = 30 days;
    uint256 constant LOCK = 30 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        aUsdc = new MockAToken(address(usdc));
        aavePool = new MockAavePool(IERC20(address(usdc)), aUsdc);

        usdc.mint(address(aavePool), 10_000_000_000_000); // huge liquidity

        insurance = new AgentInsurance(
            IERC20(address(usdc)),
            IAavePool(address(aavePool)),
            IERC20(address(aUsdc)),
            treasury,
            owner,
            PREMIUM,
            COVERAGE_MULT,
            FEE_BPS
        );

        // fund agents
        for (uint256 i; i < 3; i++) {
            address a = i == 0 ? agent1 : (i == 1 ? agent2 : agent3);
            usdc.mint(a, 1_000_000_000); // $1K each
            vm.prank(a);
            usdc.approve(address(insurance), type(uint256).max);
        }
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(insurance.paymentToken()), address(usdc));
        assertEq(insurance.treasury(), treasury);
        assertEq(insurance.owner(), owner);
        assertEq(insurance.monthlyPremium(), PREMIUM);
        assertEq(insurance.coverageMultiplier(), COVERAGE_MULT);
        assertEq(insurance.platformFeeBps(), FEE_BPS);
        assertEq(insurance.activeMemberCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentInsurance.ZeroAddress.selector);
        new AgentInsurance(IERC20(address(0)), IAavePool(address(aavePool)), IERC20(address(aUsdc)), treasury, owner, PREMIUM, COVERAGE_MULT, FEE_BPS);
    }

    function test_revert_constructorZeroPremium() public {
        vm.expectRevert(IAgentInsurance.ZeroAmount.selector);
        new AgentInsurance(IERC20(address(usdc)), IAavePool(address(aavePool)), IERC20(address(aUsdc)), treasury, owner, 0, COVERAGE_MULT, FEE_BPS);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.FeeTooHigh.selector, 5001));
        new AgentInsurance(IERC20(address(usdc)), IAavePool(address(aavePool)), IERC20(address(aUsdc)), treasury, owner, PREMIUM, COVERAGE_MULT, 5001);
    }

    // ─── Join Pool ──────────────────────────────────────────────────────

    function test_joinPool() public {
        vm.prank(agent1);
        insurance.joinPool(3); // 3 months

        IAgentInsurance.Member memory m = insurance.getMember(agent1);
        assertTrue(m.active);
        assertEq(m.premiumPaid, PREMIUM * 3);
        assertEq(m.maxCoverage, PREMIUM * 3 * COVERAGE_MULT); // $300
        assertEq(m.claimedAmount, 0);
        assertEq(insurance.activeMemberCount(), 1);
    }

    function test_joinPool_feeToTreasury() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(agent1);
        insurance.joinPool(1);

        uint256 expectedFee = PREMIUM * FEE_BPS / BPS; // 15% of $10 = $1.50
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
    }

    function test_joinPool_fundsToAave() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        uint256 totalPremium = PREMIUM;
        uint256 fee = totalPremium * FEE_BPS / BPS;
        uint256 poolAmount = totalPremium - fee;

        assertEq(insurance.poolBalance(), poolAmount);
    }

    function test_joinPool_multipleAgents() public {
        vm.prank(agent1);
        insurance.joinPool(1);
        vm.prank(agent2);
        insurance.joinPool(3);

        assertEq(insurance.activeMemberCount(), 2);
        assertTrue(insurance.isActiveMember(agent1));
        assertTrue(insurance.isActiveMember(agent2));
    }

    function test_revert_joinPoolZeroMonths() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentInsurance.InvalidMonths.selector);
        insurance.joinPool(0);
    }

    function test_revert_joinPoolTooManyMonths() public {
        vm.prank(agent1);
        vm.expectRevert(IAgentInsurance.InvalidMonths.selector);
        insurance.joinPool(13);
    }

    function test_revert_joinPoolAlreadyMember() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.AlreadyMember.selector, agent1));
        insurance.joinPool(1);
    }

    function test_revert_joinPoolWhenPaused() public {
        vm.prank(owner);
        insurance.pause();

        vm.prank(agent1);
        vm.expectRevert();
        insurance.joinPool(1);
    }

    // ─── Renew Premium ──────────────────────────────────────────────────

    function test_renewPremium() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        IAgentInsurance.Member memory before = insurance.getMember(agent1);

        vm.prank(agent1);
        insurance.renewPremium(2);

        IAgentInsurance.Member memory after_ = insurance.getMember(agent1);
        assertEq(after_.premiumPaid, PREMIUM * 3); // 1 + 2 months
        assertEq(after_.maxCoverage, PREMIUM * 3 * COVERAGE_MULT);
        assertEq(after_.coverageEnd, before.coverageEnd + uint48(2 * MONTH));
    }

    function test_renewAfterExpiry() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.warp(block.timestamp + MONTH + 1 days);
        assertFalse(insurance.isActiveMember(agent1));

        vm.prank(agent1);
        insurance.renewPremium(1);

        assertTrue(insurance.isActiveMember(agent1));
    }

    function test_revert_renewNotMember() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.NotMember.selector, agent1));
        insurance.renewPremium(1);
    }

    // ─── Leave Pool ─────────────────────────────────────────────────────

    function test_leavePool() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        insurance.leavePool();

        assertFalse(insurance.getMember(agent1).active);
        assertEq(insurance.activeMemberCount(), 0);
    }

    function test_revert_leavePoolBeforeLock() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.prank(agent1);
        vm.expectRevert();
        insurance.leavePool();
    }

    function test_revert_leavePoolNotMember() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.NotMember.selector, agent1));
        insurance.leavePool();
    }

    function test_leavePoolWorksWhenPaused() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(owner);
        insurance.pause();

        // agents can always leave
        vm.prank(agent1);
        insurance.leavePool();
        assertFalse(insurance.getMember(agent1).active);
    }

    // ─── Claim Loss ─────────────────────────────────────────────────────

    function test_claimLoss() public {
        vm.prank(agent1);
        insurance.joinPool(3); // $30 premium, $300 coverage

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        insurance.claimLoss(50_000_000); // $50

        IAgentInsurance.Member memory m = insurance.getMember(agent1);
        assertTrue(m.hasPendingClaim);
        assertEq(insurance.pendingClaimsTotal(), 50_000_000);
    }

    function test_revert_claimBeforeLock() public {
        vm.prank(agent1);
        insurance.joinPool(3);

        vm.prank(agent1);
        vm.expectRevert();
        insurance.claimLoss(50_000_000);
    }

    function test_revert_claimExceedsCoverage() public {
        vm.prank(agent1);
        insurance.joinPool(3); // $30 premium, $300 coverage

        vm.warp(block.timestamp + LOCK + 1);

        uint256 maxCoverage = PREMIUM * 3 * COVERAGE_MULT;
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            IAgentInsurance.ClaimTooLarge.selector, maxCoverage + 1, maxCoverage
        ));
        insurance.claimLoss(maxCoverage + 1);
    }

    function test_revert_claimExpired() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.warp(block.timestamp + MONTH + 1 days);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.CoverageExpired.selector, agent1));
        insurance.claimLoss(50_000_000);
    }

    function test_revert_claimNotMember() public {
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.NotMember.selector, agent1));
        insurance.claimLoss(50_000_000);
    }

    function test_revert_claimZeroAmount() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        vm.expectRevert(IAgentInsurance.ZeroAmount.selector);
        insurance.claimLoss(0);
    }

    function test_revert_duplicateClaim() public {
        vm.prank(agent1);
        insurance.joinPool(3);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        insurance.claimLoss(10_000_000);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.ClaimAlreadyPending.selector, agent1));
        insurance.claimLoss(10_000_000);
    }

    // ─── Verify & Pay ───────────────────────────────────────────────────

    function test_verifyAndPay() public {
        // seed pool — multiple agents join to build capital
        vm.prank(agent1);
        insurance.joinPool(6);
        vm.prank(agent2);
        insurance.joinPool(6);
        vm.prank(agent3);
        insurance.joinPool(6);

        vm.warp(block.timestamp + LOCK + 1);

        uint256 claimAmt = 20_000_000; // $20 — within pool balance

        vm.prank(agent1);
        insurance.claimLoss(claimAmt);

        uint256 agent1Before = usdc.balanceOf(agent1);

        vm.prank(owner);
        insurance.verifyAndPay(agent1);

        assertEq(usdc.balanceOf(agent1) - agent1Before, claimAmt);
        assertFalse(insurance.getMember(agent1).hasPendingClaim);
        assertEq(insurance.getMember(agent1).claimedAmount, claimAmt);
        assertEq(insurance.totalClaimsPaid(), claimAmt);
        assertEq(insurance.pendingClaimsTotal(), 0);
    }

    function test_revert_verifyNotOwner() public {
        vm.prank(agent1);
        insurance.joinPool(3);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        insurance.claimLoss(50_000_000);

        vm.prank(agent2);
        vm.expectRevert();
        insurance.verifyAndPay(agent1);
    }

    function test_revert_verifyNoPendingClaim() public {
        vm.prank(agent1);
        insurance.joinPool(1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsurance.NoPendingClaim.selector, agent1));
        insurance.verifyAndPay(agent1);
    }

    // ─── Reject Claim ───────────────────────────────────────────────────

    function test_rejectClaim() public {
        vm.prank(agent1);
        insurance.joinPool(3);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        insurance.claimLoss(50_000_000);

        vm.prank(owner);
        insurance.rejectClaim(agent1);

        assertFalse(insurance.getMember(agent1).hasPendingClaim);
        assertEq(insurance.getMember(agent1).claimedAmount, 0);
        assertEq(insurance.pendingClaimsTotal(), 0);
    }

    function test_claimAfterRejection() public {
        vm.prank(agent1);
        insurance.joinPool(3);

        vm.warp(block.timestamp + LOCK + 1);

        vm.prank(agent1);
        insurance.claimLoss(50_000_000);

        vm.prank(owner);
        insurance.rejectClaim(agent1);

        // agent can submit a new claim
        vm.prank(agent1);
        insurance.claimLoss(30_000_000);

        assertTrue(insurance.getMember(agent1).hasPendingClaim);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setMonthlyPremium() public {
        vm.prank(owner);
        insurance.setMonthlyPremium(25_000_000);
        assertEq(insurance.monthlyPremium(), 25_000_000);
    }

    function test_setCoverageMultiplier() public {
        vm.prank(owner);
        insurance.setCoverageMultiplier(5);
        assertEq(insurance.coverageMultiplier(), 5);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newTreasury");
        vm.prank(owner);
        insurance.setTreasury(newT);
        assertEq(insurance.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentInsurance.ZeroAddress.selector);
        insurance.setTreasury(address(0));
    }

    // ─── Multi-Claim Scenario ───────────────────────────────────────────

    function test_multipleClaimsReduceCoverage() public {
        // seed pool with enough capital
        vm.prank(agent1);
        insurance.joinPool(6);
        vm.prank(agent2);
        insurance.joinPool(12);
        vm.prank(agent3);
        insurance.joinPool(12);

        vm.warp(block.timestamp + LOCK + 1);

        // agent1 has $600 coverage (6 months × $10 × 10x)
        // first claim: $20
        vm.prank(agent1);
        insurance.claimLoss(20_000_000);
        vm.prank(owner);
        insurance.verifyAndPay(agent1);

        // second claim: $30
        vm.prank(agent1);
        insurance.claimLoss(30_000_000);
        vm.prank(owner);
        insurance.verifyAndPay(agent1);

        // cumulative claimed: $50. remaining: $600 - $50 = $550
        // claim $551 exceeds
        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(
            IAgentInsurance.ClaimTooLarge.selector, 551_000_000, 550_000_000
        ));
        insurance.claimLoss(551_000_000);

        // $10 works
        vm.prank(agent1);
        insurance.claimLoss(10_000_000);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_joinPoolFeeCorrect(uint256 months) public {
        months = bound(months, 1, 12);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(agent1);
        insurance.joinPool(months);

        uint256 totalPremium = PREMIUM * months;
        uint256 expectedFee = totalPremium * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
    }

    function testFuzz_coverageCorrect(uint256 months) public {
        months = bound(months, 1, 12);

        vm.prank(agent1);
        insurance.joinPool(months);

        IAgentInsurance.Member memory m = insurance.getMember(agent1);
        assertEq(m.maxCoverage, PREMIUM * months * COVERAGE_MULT);
    }

    function testFuzz_claimWithinCoverage(uint256 months, uint256 claimPct) public {
        months = bound(months, 2, 12); // need >1 month so coverage outlasts lock
        claimPct = bound(claimPct, 1, 100);

        vm.prank(agent1);
        insurance.joinPool(months);

        vm.warp(block.timestamp + LOCK + 1);

        uint256 maxCoverage = PREMIUM * months * COVERAGE_MULT;
        uint256 claimAmount = maxCoverage * claimPct / 100;
        if (claimAmount == 0) claimAmount = 1;

        vm.prank(agent1);
        insurance.claimLoss(claimAmount);

        assertTrue(insurance.getMember(agent1).hasPendingClaim);
    }
}
