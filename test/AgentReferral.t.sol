// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentReferral} from "../src/AgentReferral.sol";
import {IAgentReferral} from "../src/interfaces/IAgentReferral.sol";

contract AgentReferralTest is Test {
    ERC20Mock usdc;
    AgentReferral referral;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice"); // referrer
    address bob = makeAddr("bob"); // referred agent
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
    address protocol = makeAddr("protocol"); // authorized protocol

    uint256 constant REFERRAL_BPS = 1000; // 10%
    uint256 constant BPS = 10_000;
    uint256 constant FEE_AMOUNT = 1_000_000_000; // $1000 USDC (6 decimals)

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        referral = new AgentReferral(IERC20(address(usdc)), owner, REFERRAL_BPS);

        vm.prank(owner);
        referral.authorizeProtocol(protocol);

        usdc.mint(protocol, 100_000_000_000);
        vm.prank(protocol);
        usdc.approve(address(referral), type(uint256).max);

        vm.deal(protocol, 100 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(referral.paymentToken()), address(usdc));
        assertEq(referral.owner(), owner);
        assertEq(referral.referralBps(), REFERRAL_BPS);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentReferral.ZeroAddress.selector);
        new AgentReferral(IERC20(address(0)), owner, REFERRAL_BPS);
    }

    function test_revert_constructorBpsTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.ReferralBpsTooHigh.selector, 2001));
        new AgentReferral(IERC20(address(usdc)), owner, 2001);
    }

    // ─── Register Referral ──────────────────────────────────────────────

    function test_registerReferral() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        assertEq(referral.getReferrer(bob), alice);
        assertTrue(referral.isRegistered(bob));

        address[] memory referrees = referral.getReferrees(alice);
        assertEq(referrees.length, 1);
        assertEq(referrees[0], bob);
    }

    function test_registerMultipleReferrees() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(charlie);
        referral.registerReferral(alice);

        address[] memory referrees = referral.getReferrees(alice);
        assertEq(referrees.length, 2);
        assertEq(referrees[0], bob);
        assertEq(referrees[1], charlie);
    }

    function test_revert_registerSelfReferral() public {
        vm.prank(alice);
        vm.expectRevert(IAgentReferral.SelfReferral.selector);
        referral.registerReferral(alice);
    }

    function test_revert_registerZeroReferrer() public {
        vm.prank(bob);
        vm.expectRevert(IAgentReferral.ZeroAddress.selector);
        referral.registerReferral(address(0));
    }

    function test_revert_registerAlreadyRegistered() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.AlreadyRegistered.selector, bob));
        referral.registerReferral(charlie);
    }

    function test_revert_registerCircularDirect() public {
        // alice refers bob
        vm.prank(bob);
        referral.registerReferral(alice);

        // bob tries to refer alice → circular
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.CircularReferral.selector, alice, bob));
        referral.registerReferral(bob);
    }

    function test_revert_registerCircularIndirect() public {
        // chain: bob→alice, charlie→bob
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(charlie);
        referral.registerReferral(bob);

        // alice tries to register with charlie → alice→charlie→bob→alice (cycle)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.CircularReferral.selector, alice, charlie));
        referral.registerReferral(charlie);
    }

    function test_revert_registerWhenPaused() public {
        vm.prank(owner);
        referral.pause();

        vm.prank(bob);
        vm.expectRevert();
        referral.registerReferral(alice);
    }

    function test_registerImmutable() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        // can't change referrer
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.AlreadyRegistered.selector, bob));
        referral.registerReferral(charlie);

        // still alice
        assertEq(referral.getReferrer(bob), alice);
    }

    // ─── Record Fee (USDC) ──────────────────────────────────────────────

    function test_recordFeeUsdc() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        uint256 reward = FEE_AMOUNT * REFERRAL_BPS / BPS;
        (uint256 ethPending, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, reward);
        assertEq(ethPending, 0);
    }

    function test_recordFeeUsdc_pullsTokens() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        uint256 protocolBefore = usdc.balanceOf(protocol);
        uint256 reward = FEE_AMOUNT * REFERRAL_BPS / BPS;

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        assertEq(protocolBefore - usdc.balanceOf(protocol), reward);
        assertEq(usdc.balanceOf(address(referral)), reward);
    }

    function test_recordFeeUsdc_accumulatesMultipleFees() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        uint256 reward = FEE_AMOUNT * REFERRAL_BPS / BPS;
        (, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, reward * 2);
    }

    // ─── Record Fee (ETH) ───────────────────────────────────────────────

    function test_recordFeeEth() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        uint256 ethFee = 0.01 ether;
        uint256 reward = ethFee * REFERRAL_BPS / BPS;

        vm.prank(protocol);
        referral.recordFee{value: reward}(bob, ethFee, address(0));

        (uint256 ethPending,) = referral.getPendingRewards(alice);
        assertEq(ethPending, reward);
    }

    function test_recordFeeEth_refundsExcess() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        uint256 ethFee = 0.01 ether;
        uint256 reward = ethFee * REFERRAL_BPS / BPS;
        uint256 sent = reward + 0.001 ether; // overpay

        uint256 protocolBefore = protocol.balance;

        vm.prank(protocol);
        referral.recordFee{value: sent}(bob, ethFee, address(0));

        // only reward kept, excess refunded
        assertEq(protocolBefore - protocol.balance, reward);
    }

    function test_revert_recordFeeEth_insufficientValue() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        uint256 ethFee = 0.01 ether;
        uint256 reward = ethFee * REFERRAL_BPS / BPS;

        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.InsufficientEthForReward.selector, reward, reward - 1));
        referral.recordFee{value: reward - 1}(bob, ethFee, address(0));
    }

    function test_revert_recordFeeUsdc_unexpectedEth() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        vm.expectRevert(IAgentReferral.UnexpectedEth.selector);
        referral.recordFee{value: 0.001 ether}(bob, FEE_AMOUNT, address(usdc));
    }

    // ─── Record Fee (no referrer / unauthorized) ────────────────────────

    function test_recordFee_noReferrer_noop() public {
        // bob has no referrer — should be a noop
        uint256 protocolUsdcBefore = usdc.balanceOf(protocol);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        // no tokens pulled
        assertEq(usdc.balanceOf(protocol), protocolUsdcBefore);
    }

    function test_recordFee_noReferrer_refundsEth() public {
        uint256 protocolBefore = protocol.balance;

        vm.prank(protocol);
        referral.recordFee{value: 0.001 ether}(bob, 0.01 ether, address(0));

        // ETH refunded
        assertEq(protocol.balance, protocolBefore);
    }

    function test_revert_recordFee_unauthorized() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.NotAuthorizedProtocol.selector, charlie));
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));
    }

    function test_revert_recordFee_invalidToken() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        address fakeToken = makeAddr("fakeToken");

        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.InvalidFeeToken.selector, fakeToken));
        referral.recordFee(bob, FEE_AMOUNT, fakeToken);
    }

    // ─── Claim Rewards ──────────────────────────────────────────────────

    function test_claimRewards_usdc() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        uint256 reward = FEE_AMOUNT * REFERRAL_BPS / BPS;
        uint256 aliceBefore = usdc.balanceOf(alice);

        referral.claimReferralRewards(alice);

        assertEq(usdc.balanceOf(alice) - aliceBefore, reward);

        (, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, 0);
    }

    function test_claimRewards_eth() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        uint256 ethFee = 0.01 ether;
        uint256 reward = ethFee * REFERRAL_BPS / BPS;

        vm.prank(protocol);
        referral.recordFee{value: reward}(bob, ethFee, address(0));

        uint256 aliceBefore = alice.balance;

        referral.claimReferralRewards(alice);

        assertEq(alice.balance - aliceBefore, reward);
    }

    function test_claimRewards_both() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        // USDC fee
        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        // ETH fee
        uint256 ethFee = 0.01 ether;
        uint256 ethReward = ethFee * REFERRAL_BPS / BPS;
        vm.prank(protocol);
        referral.recordFee{value: ethReward}(bob, ethFee, address(0));

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        referral.claimReferralRewards(alice);

        uint256 usdcReward = FEE_AMOUNT * REFERRAL_BPS / BPS;
        assertEq(alice.balance - aliceEthBefore, ethReward);
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, usdcReward);
    }

    function test_claimRewards_anyoneCanTrigger() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        uint256 aliceBefore = usdc.balanceOf(alice);

        // charlie triggers claim for alice — rewards go to alice
        vm.prank(charlie);
        referral.claimReferralRewards(alice);

        uint256 reward = FEE_AMOUNT * REFERRAL_BPS / BPS;
        assertEq(usdc.balanceOf(alice) - aliceBefore, reward);
    }

    function test_revert_claimNoRewards() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.NoPendingRewards.selector, alice));
        referral.claimReferralRewards(alice);
    }

    function test_claimRewards_doubleClaim() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        referral.claimReferralRewards(alice);

        // second claim reverts — no pending
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.NoPendingRewards.selector, alice));
        referral.claimReferralRewards(alice);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_authorizeProtocol() public {
        address newProtocol = makeAddr("newProtocol");

        vm.prank(owner);
        referral.authorizeProtocol(newProtocol);

        assertTrue(referral.isAuthorizedProtocol(newProtocol));
    }

    function test_revokeProtocol() public {
        vm.prank(owner);
        referral.revokeProtocol(protocol);

        assertFalse(referral.isAuthorizedProtocol(protocol));
    }

    function test_revert_authorizeZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAgentReferral.ZeroAddress.selector);
        referral.authorizeProtocol(address(0));
    }

    function test_revert_authorizeNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        referral.authorizeProtocol(makeAddr("x"));
    }

    function test_setReferralBps() public {
        vm.prank(owner);
        referral.setReferralBps(500); // 5%

        assertEq(referral.referralBps(), 500);
    }

    function test_revert_setReferralBpsTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.ReferralBpsTooHigh.selector, 2001));
        referral.setReferralBps(2001);
    }

    function test_revert_setReferralBpsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        referral.setReferralBps(500);
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        referral.pause();

        vm.prank(bob);
        vm.expectRevert();
        referral.registerReferral(alice);

        vm.prank(owner);
        referral.unpause();

        vm.prank(bob);
        referral.registerReferral(alice);
    }

    // ─── View / Stats ───────────────────────────────────────────────────

    function test_getReferralStats() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(charlie);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        vm.prank(protocol);
        referral.recordFee(charlie, FEE_AMOUNT / 2, address(usdc));

        IAgentReferral.ReferralStats memory stats = referral.getReferralStats(alice);
        assertEq(stats.totalReferrees, 2);
        assertEq(stats.totalFeesGenerated, FEE_AMOUNT + FEE_AMOUNT / 2);

        uint256 totalReward = (FEE_AMOUNT + FEE_AMOUNT / 2) * REFERRAL_BPS / BPS;
        assertEq(stats.totalEarnedUsdc, totalReward);
        assertEq(stats.totalEarnedEth, 0);
    }

    function test_getReferralStats_afterClaim() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        referral.claimReferralRewards(alice);

        // add more fees after claim
        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        IAgentReferral.ReferralStats memory stats = referral.getReferralStats(alice);
        uint256 reward = FEE_AMOUNT * REFERRAL_BPS / BPS;
        assertEq(stats.totalEarnedUsdc, reward * 2); // claimed + pending
    }

    function test_getReferrer_unregistered() public view {
        assertEq(referral.getReferrer(bob), address(0));
    }

    function test_getReferrees_empty() public view {
        address[] memory referrees = referral.getReferrees(alice);
        assertEq(referrees.length, 0);
    }

    // ─── Edge Cases ─────────────────────────────────────────────────────

    function test_multipleReferrees_separateRewards() public {
        // alice refers both bob and charlie
        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(charlie);
        referral.registerReferral(alice);

        // bob generates 1000 USDC fee, charlie generates 500
        vm.prank(protocol);
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));

        vm.prank(protocol);
        referral.recordFee(charlie, FEE_AMOUNT / 2, address(usdc));

        uint256 totalReward = (FEE_AMOUNT + FEE_AMOUNT / 2) * REFERRAL_BPS / BPS;
        (, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, totalReward);
    }

    function test_referrerDoesNotNeedRegistration() public {
        // alice is not registered, but can still be a referrer
        assertFalse(referral.isRegistered(alice));

        vm.prank(bob);
        referral.registerReferral(alice);

        assertEq(referral.getReferrer(bob), alice);
    }

    function test_revokedProtocol_cannotRecordFee() public {
        vm.prank(owner);
        referral.revokeProtocol(protocol);

        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.NotAuthorizedProtocol.selector, protocol));
        referral.recordFee(bob, FEE_AMOUNT, address(usdc));
    }

    function test_zeroReward_noTransfer() public {
        vm.prank(bob);
        referral.registerReferral(alice);

        // fee so small that reward rounds to 0
        uint256 tinyFee = 1; // 1 unit, 10% = 0
        uint256 protocolBefore = usdc.balanceOf(protocol);

        vm.prank(protocol);
        referral.recordFee(bob, tinyFee, address(usdc));

        // no tokens pulled
        assertEq(usdc.balanceOf(protocol), protocolBefore);
        (, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, 0);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_rewardCalculation(uint256 feeAmount) public {
        feeAmount = bound(feeAmount, 10, 1_000_000_000_000); // $0.00001 to $1M

        vm.prank(bob);
        referral.registerReferral(alice);

        usdc.mint(protocol, feeAmount);

        vm.prank(protocol);
        referral.recordFee(bob, feeAmount, address(usdc));

        uint256 expectedReward = feeAmount * REFERRAL_BPS / BPS;
        (, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, expectedReward);
    }

    function testFuzz_claimRoundTrip(uint256 feeAmount) public {
        feeAmount = bound(feeAmount, 1_000_000, 1_000_000_000_000);

        vm.prank(bob);
        referral.registerReferral(alice);

        usdc.mint(protocol, feeAmount);

        vm.prank(protocol);
        referral.recordFee(bob, feeAmount, address(usdc));

        uint256 aliceBefore = usdc.balanceOf(alice);

        referral.claimReferralRewards(alice);

        uint256 expectedReward = feeAmount * REFERRAL_BPS / BPS;
        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedReward);

        // nothing pending after claim
        (, uint256 usdcPending) = referral.getPendingRewards(alice);
        assertEq(usdcPending, 0);
    }

    function testFuzz_ethRewardExactMatch(uint256 ethFee) public {
        ethFee = bound(ethFee, 0.0001 ether, 10 ether);

        vm.prank(bob);
        referral.registerReferral(alice);

        uint256 reward = ethFee * REFERRAL_BPS / BPS;
        vm.deal(protocol, reward + 1 ether);

        vm.prank(protocol);
        referral.recordFee{value: reward}(bob, ethFee, address(0));

        (uint256 ethPending,) = referral.getPendingRewards(alice);
        assertEq(ethPending, reward);
    }

    function testFuzz_cannotRegisterAfterFirst(address randomReferrer) public {
        vm.assume(randomReferrer != address(0));
        vm.assume(randomReferrer != bob);

        vm.prank(bob);
        referral.registerReferral(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentReferral.AlreadyRegistered.selector, bob));
        referral.registerReferral(randomReferrer);
    }
}
