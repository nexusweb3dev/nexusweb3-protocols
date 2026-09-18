// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockReferral} from "./mocks/MockReferral.sol";
import {FeeRouter} from "../../src/v2/FeeRouter.sol";
import {IFeeRouter} from "../../src/v2/interfaces/IFeeRouter.sol";

contract FeeRouterTest is Test {
    ERC20Mock usdc;
    MockReferral referral;
    FeeRouter router;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address staking = makeAddr("staking");
    address protocol = makeAddr("protocol");
    address agent = makeAddr("agent");
    address referrer = makeAddr("referrer");
    address stranger = makeAddr("stranger");

    uint16 constant STAKING_BPS = 7000;
    uint16 constant TREASURY_BPS = 3000;
    uint256 constant REFERRAL_BPS = 1000; // 10%
    uint256 constant BPS = 10_000;
    uint256 constant AMOUNT = 1_000_000_000; // $1000 USDC

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        referral = new MockReferral(IERC20(address(usdc)), REFERRAL_BPS);
        router = new FeeRouter(
            IERC20(address(usdc)), owner, treasury, staking, address(referral), STAKING_BPS, TREASURY_BPS
        );

        vm.prank(owner);
        router.authorizeProtocol(protocol);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(address(router), amount);
    }

    function _route(address agent_, uint256 amount) internal {
        vm.prank(protocol);
        router.route(agent_, amount);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(router.paymentToken(), address(usdc));
        assertEq(router.owner(), owner);
        assertEq(router.treasury(), treasury);
        assertEq(router.stakingRecipient(), staking);
        assertEq(router.referral(), address(referral));
        (uint16 s, uint16 t) = router.split();
        assertEq(s, STAKING_BPS);
        assertEq(t, TREASURY_BPS);
        assertEq(usdc.allowance(address(router), address(referral)), type(uint256).max);
    }

    function test_constructor_zeroReferralSkipsApproval() public {
        FeeRouter bare =
            new FeeRouter(IERC20(address(usdc)), owner, treasury, staking, address(0), STAKING_BPS, TREASURY_BPS);
        assertEq(bare.referral(), address(0));
        assertEq(usdc.allowance(address(bare), address(referral)), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        new FeeRouter(IERC20(address(0)), owner, treasury, staking, address(0), STAKING_BPS, TREASURY_BPS);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        new FeeRouter(IERC20(address(usdc)), owner, address(0), staking, address(0), STAKING_BPS, TREASURY_BPS);
    }

    function test_revert_constructorZeroStakingRecipient() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        new FeeRouter(IERC20(address(usdc)), owner, treasury, address(0), address(0), STAKING_BPS, TREASURY_BPS);
    }

    function test_revert_constructorInvalidSplit() public {
        vm.expectRevert(IFeeRouter.InvalidSplit.selector);
        new FeeRouter(IERC20(address(usdc)), owner, treasury, staking, address(0), 6000, 3000);
    }

    // ─── Routing ────────────────────────────────────────────────────────

    function test_route_noReferrerSplitsFullAmount() public {
        _fund(AMOUNT);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(address(referral)), 0);
        assertEq(usdc.balanceOf(staking), (AMOUNT * STAKING_BPS) / BPS);
        assertEq(usdc.balanceOf(treasury), (AMOUNT * TREASURY_BPS) / BPS);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_route_withReferrerPaysReferralFirst() public {
        referral.setReferrer(agent, referrer);
        _fund(AMOUNT);
        _route(agent, AMOUNT);

        uint256 expectedReferral = (AMOUNT * REFERRAL_BPS) / BPS;
        uint256 remainder = AMOUNT - expectedReferral;

        assertEq(usdc.balanceOf(address(referral)), expectedReferral);
        assertEq(referral.pending(referrer), expectedReferral);
        assertEq(usdc.balanceOf(staking), (remainder * STAKING_BPS) / BPS);
        assertEq(usdc.balanceOf(treasury), remainder - (remainder * STAKING_BPS) / BPS);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_route_referralRevertDoesNotBlockRouting() public {
        referral.setReferrer(agent, referrer);
        referral.setShouldRevert(true);
        _fund(AMOUNT);

        vm.expectEmit(true, true, false, true, address(router));
        emit IFeeRouter.FeeRouted(
            protocol, agent, AMOUNT, 0, (AMOUNT * STAKING_BPS) / BPS, (AMOUNT * TREASURY_BPS) / BPS
        );
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(address(referral)), 0);
        assertEq(usdc.balanceOf(staking), (AMOUNT * STAKING_BPS) / BPS);
        assertEq(usdc.balanceOf(treasury), (AMOUNT * TREASURY_BPS) / BPS);
    }

    function test_route_referralDisabled() public {
        vm.prank(owner);
        router.setReferral(address(0));
        referral.setReferrer(agent, referrer);

        _fund(AMOUNT);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(address(referral)), 0);
        assertEq(usdc.balanceOf(staking) + usdc.balanceOf(treasury), AMOUNT);
    }

    function test_route_dustGoesToTreasury() public {
        vm.prank(owner);
        router.setSplit(5000, 5000);

        _fund(1);
        _route(agent, 1);

        assertEq(usdc.balanceOf(staking), 0);
        assertEq(usdc.balanceOf(treasury), 1);
    }

    function test_route_allToStaking() public {
        vm.prank(owner);
        router.setSplit(10_000, 0);

        _fund(AMOUNT);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(staking), AMOUNT);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_route_allToTreasury() public {
        vm.prank(owner);
        router.setSplit(0, 10_000);

        _fund(AMOUNT);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(staking), 0);
        assertEq(usdc.balanceOf(treasury), AMOUNT);
    }

    function test_route_leavesSurplusBalanceUntouched() public {
        _fund(AMOUNT * 3);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(address(router)), AMOUNT * 2);
        assertEq(usdc.balanceOf(staking) + usdc.balanceOf(treasury), AMOUNT);
    }

    function test_route_emitsFeeRoutedWithReferral() public {
        referral.setReferrer(agent, referrer);
        _fund(AMOUNT);

        uint256 expectedReferral = (AMOUNT * REFERRAL_BPS) / BPS;
        uint256 remainder = AMOUNT - expectedReferral;
        uint256 stakingShare = (remainder * STAKING_BPS) / BPS;

        vm.expectEmit(true, true, false, true, address(router));
        emit IFeeRouter.FeeRouted(protocol, agent, AMOUNT, expectedReferral, stakingShare, remainder - stakingShare);
        _route(agent, AMOUNT);
    }

    function test_route_overPullingReferralIsClamped() public {
        MockReferral greedy = new MockReferral(IERC20(address(usdc)), 20_000); // pulls 200% of the fee
        greedy.setReferrer(agent, referrer);
        vm.prank(owner);
        router.setReferral(address(greedy));

        _fund(AMOUNT * 3);

        vm.expectEmit(true, true, false, true, address(router));
        emit IFeeRouter.FeeRouted(protocol, agent, AMOUNT, AMOUNT, 0, 0);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(staking), 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_route_twiceAccumulates() public {
        _fund(AMOUNT * 2);
        _route(agent, AMOUNT);
        _route(agent, AMOUNT);

        assertEq(usdc.balanceOf(staking), (AMOUNT * 2 * STAKING_BPS) / BPS);
        assertEq(usdc.balanceOf(treasury), (AMOUNT * 2 * TREASURY_BPS) / BPS);
    }

    function test_revert_routeUnauthorizedCaller() public {
        _fund(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IFeeRouter.NotAuthorizedProtocol.selector, stranger));
        vm.prank(stranger);
        router.route(agent, AMOUNT);
    }

    function test_revert_routeAfterRevoke() public {
        vm.prank(owner);
        router.revokeProtocol(protocol);

        _fund(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IFeeRouter.NotAuthorizedProtocol.selector, protocol));
        _route(agent, AMOUNT);
    }

    function test_revert_routeZeroAmount() public {
        _fund(AMOUNT);
        vm.expectRevert(IFeeRouter.ZeroAmount.selector);
        _route(agent, 0);
    }

    function test_revert_routeInsufficientBalance() public {
        _fund(AMOUNT - 1);
        vm.expectRevert(abi.encodeWithSelector(IFeeRouter.InsufficientBalance.selector, AMOUNT, AMOUNT - 1));
        _route(agent, AMOUNT);
    }

    // ─── setSplit ───────────────────────────────────────────────────────

    function test_setSplit() public {
        vm.expectEmit(false, false, false, true, address(router));
        emit IFeeRouter.SplitUpdated(2500, 7500);
        vm.prank(owner);
        router.setSplit(2500, 7500);

        (uint16 s, uint16 t) = router.split();
        assertEq(s, 2500);
        assertEq(t, 7500);
    }

    function test_revert_setSplitInvalid() public {
        vm.expectRevert(IFeeRouter.InvalidSplit.selector);
        vm.prank(owner);
        router.setSplit(5000, 4000);
    }

    function test_revert_setSplitNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setSplit(5000, 5000);
    }

    // ─── setRecipients ──────────────────────────────────────────────────

    function test_setRecipients() public {
        address newTreasury = makeAddr("newTreasury");
        address newStaking = makeAddr("newStaking");

        vm.expectEmit(true, true, false, false, address(router));
        emit IFeeRouter.RecipientsUpdated(newTreasury, newStaking);
        vm.prank(owner);
        router.setRecipients(newTreasury, newStaking);

        assertEq(router.treasury(), newTreasury);
        assertEq(router.stakingRecipient(), newStaking);
    }

    function test_revert_setRecipientsZeroTreasury() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.setRecipients(address(0), staking);
    }

    function test_revert_setRecipientsZeroStaking() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.setRecipients(treasury, address(0));
    }

    function test_revert_setRecipientsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setRecipients(treasury, staking);
    }

    // ─── setReferral ────────────────────────────────────────────────────

    function test_setReferral_movesAllowance() public {
        MockReferral next = new MockReferral(IERC20(address(usdc)), REFERRAL_BPS);

        vm.expectEmit(true, false, false, false, address(router));
        emit IFeeRouter.ReferralUpdated(address(next));
        vm.prank(owner);
        router.setReferral(address(next));

        assertEq(router.referral(), address(next));
        assertEq(usdc.allowance(address(router), address(referral)), 0);
        assertEq(usdc.allowance(address(router), address(next)), type(uint256).max);
    }

    function test_setReferral_disableZeroesAllowance() public {
        vm.prank(owner);
        router.setReferral(address(0));

        assertEq(router.referral(), address(0));
        assertEq(usdc.allowance(address(router), address(referral)), 0);
    }

    function test_setReferral_enableFromZeroGrantsMax() public {
        vm.startPrank(owner);
        router.setReferral(address(0));
        router.setReferral(address(referral));
        vm.stopPrank();

        assertEq(usdc.allowance(address(router), address(referral)), type(uint256).max);
    }

    function test_revert_setReferralNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setReferral(address(0));
    }

    // ─── Protocol authorization ─────────────────────────────────────────

    function test_authorizeProtocol() public {
        vm.expectEmit(true, false, false, false, address(router));
        emit IFeeRouter.ProtocolAuthorized(stranger);
        vm.prank(owner);
        router.authorizeProtocol(stranger);

        assertTrue(router.isAuthorizedProtocol(stranger));
    }

    function test_revert_authorizeZeroAddress() public {
        vm.expectRevert(IFeeRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.authorizeProtocol(address(0));
    }

    function test_revert_authorizeAlreadyAuthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeRouter.AlreadyAuthorized.selector, protocol));
        vm.prank(owner);
        router.authorizeProtocol(protocol);
    }

    function test_revert_authorizeNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.authorizeProtocol(stranger);
    }

    function test_revokeProtocol() public {
        vm.expectEmit(true, false, false, false, address(router));
        emit IFeeRouter.ProtocolRevoked(protocol);
        vm.prank(owner);
        router.revokeProtocol(protocol);

        assertFalse(router.isAuthorizedProtocol(protocol));
    }

    function test_revert_revokeNotAuthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeRouter.NotAuthorized.selector, stranger));
        vm.prank(owner);
        router.revokeProtocol(stranger);
    }

    function test_revert_revokeNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.revokeProtocol(protocol);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_route_splitIsExact(uint96 amount, uint16 stakingBps) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        stakingBps = uint16(bound(stakingBps, 0, 10_000));

        vm.prank(owner);
        router.setSplit(stakingBps, uint16(10_000 - stakingBps));

        _fund(amount);
        _route(agent, amount);

        assertEq(usdc.balanceOf(staking) + usdc.balanceOf(treasury), amount);
        assertEq(usdc.balanceOf(staking), (uint256(amount) * stakingBps) / BPS);
    }

    function testFuzz_route_referralPlusSharesEqualAmount(uint96 amount, uint16 stakingBps) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        stakingBps = uint16(bound(stakingBps, 0, 10_000));

        vm.prank(owner);
        router.setSplit(stakingBps, uint16(10_000 - stakingBps));
        referral.setReferrer(agent, referrer);

        _fund(amount);
        _route(agent, amount);

        uint256 paidReferral = usdc.balanceOf(address(referral));
        assertEq(paidReferral, (uint256(amount) * REFERRAL_BPS) / BPS);
        assertEq(paidReferral + usdc.balanceOf(staking) + usdc.balanceOf(treasury), amount);
    }

    function testFuzz_route_routerBalanceDropsByExactlyAmount(uint96 amount, uint96 surplus, bool withReferrer) public {
        amount = uint96(bound(amount, 1, type(uint96).max / 2));
        surplus = uint96(bound(surplus, 0, type(uint96).max / 2));
        if (withReferrer) referral.setReferrer(agent, referrer);

        _fund(uint256(amount) + uint256(surplus));
        uint256 before = usdc.balanceOf(address(router));
        _route(agent, amount);

        assertEq(before - usdc.balanceOf(address(router)), amount);
        assertEq(usdc.balanceOf(address(router)), surplus);
    }
}
