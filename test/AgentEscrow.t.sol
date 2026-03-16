// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {IAgentEscrow} from "../src/interfaces/IAgentEscrow.sol";

contract AgentEscrowTest is Test {
    ERC20Mock usdc;
    AgentEscrow escrow;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // depositor
    address bob = makeAddr("bob"); // recipient
    address charlie = makeAddr("charlie");

    uint256 constant FEE_BPS = 50; // 0.5%
    uint256 constant BPS = 10_000;
    uint256 constant AMOUNT = 1_000_000_000; // $1000 USDC
    uint48 constant ONE_DAY = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        escrow = new AgentEscrow(IERC20(address(usdc)), treasury, owner, FEE_BPS);

        usdc.mint(alice, 10_000_000_000); // $10K
        usdc.mint(bob, 10_000_000_000);
        usdc.mint(charlie, 10_000_000_000);

        vm.prank(alice);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _deadline() internal view returns (uint48) {
        return uint48(block.timestamp) + ONE_DAY;
    }

    function _createDefaultEscrow() internal returns (uint256) {
        vm.prank(alice);
        return escrow.createEscrow(bob, AMOUNT, _deadline());
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(escrow.paymentToken()), address(usdc));
        assertEq(escrow.treasury(), treasury);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.platformFeeBps(), FEE_BPS);
        assertEq(escrow.escrowCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentEscrow.ZeroAddress.selector);
        new AgentEscrow(IERC20(address(0)), treasury, owner, FEE_BPS);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentEscrow.ZeroAddress.selector);
        new AgentEscrow(IERC20(address(usdc)), address(0), owner, FEE_BPS);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.FeeTooHigh.selector, 1001));
        new AgentEscrow(IERC20(address(usdc)), treasury, owner, 1001);
    }

    // ─── Create Escrow ──────────────────────────────────────────────────

    function test_createEscrow() public {
        uint256 id = _createDefaultEscrow();

        assertEq(id, 0);
        assertEq(escrow.escrowCount(), 1);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.depositor, alice);
        assertEq(e.recipient, bob);
        assertEq(e.amount, AMOUNT);
        assertEq(e.deadline, _deadline());
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Active));
    }

    function test_createEscrow_transfersFunds() public {
        uint256 aliceBefore = usdc.balanceOf(alice);

        _createDefaultEscrow();

        assertEq(aliceBefore - usdc.balanceOf(alice), AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
    }

    function test_createMultipleEscrows() public {
        vm.startPrank(alice);
        uint256 id0 = escrow.createEscrow(bob, AMOUNT, _deadline());
        uint256 id1 = escrow.createEscrow(charlie, AMOUNT / 2, _deadline());
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(escrow.escrowCount(), 2);
    }

    function test_revert_createSelfRecipient() public {
        vm.prank(alice);
        vm.expectRevert(IAgentEscrow.InvalidRecipient.selector);
        escrow.createEscrow(alice, AMOUNT, _deadline());
    }

    function test_revert_createZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(IAgentEscrow.InvalidRecipient.selector);
        escrow.createEscrow(address(0), AMOUNT, _deadline());
    }

    function test_revert_createZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IAgentEscrow.InvalidAmount.selector);
        escrow.createEscrow(bob, 0, _deadline());
    }

    function test_revert_createDeadlineTooSoon() public {
        vm.prank(alice);
        vm.expectRevert(IAgentEscrow.InvalidDeadline.selector);
        escrow.createEscrow(bob, AMOUNT, uint48(block.timestamp + 30 minutes));
    }

    function test_revert_createDeadlineTooFar() public {
        vm.prank(alice);
        vm.expectRevert(IAgentEscrow.InvalidDeadline.selector);
        escrow.createEscrow(bob, AMOUNT, uint48(block.timestamp + 91 days));
    }

    function test_revert_createWhenPaused() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(alice);
        vm.expectRevert();
        escrow.createEscrow(bob, AMOUNT, _deadline());
    }

    // ─── Release Payment ────────────────────────────────────────────────

    function test_releaseByDepositor() public {
        uint256 id = _createDefaultEscrow();
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        escrow.releasePayment(id);

        uint256 fee = AMOUNT * FEE_BPS / BPS;
        uint256 payout = AMOUNT - fee;

        assertEq(usdc.balanceOf(bob) - bobBefore, payout);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, fee);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Released));
    }

    function test_releaseByRecipient() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(bob);
        escrow.releasePayment(id);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Released));
    }

    function test_revert_releaseByStranger() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.NotDepositor.selector, id));
        escrow.releasePayment(id);
    }

    function test_revert_releaseAlreadyReleased() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.releasePayment(id);

        vm.prank(alice);
        vm.expectRevert();
        escrow.releasePayment(id);
    }

    // ─── Refund ─────────────────────────────────────────────────────────

    function test_refundAfterDeadline() public {
        uint256 id = _createDefaultEscrow();
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.warp(block.timestamp + ONE_DAY + 1);

        vm.prank(alice);
        escrow.refundEscrow(id);

        assertEq(usdc.balanceOf(alice) - aliceBefore, AMOUNT);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Refunded));
    }

    function test_refundByAnyone() public {
        uint256 id = _createDefaultEscrow();

        vm.warp(block.timestamp + ONE_DAY + 1);

        // charlie (stranger) can trigger refund — funds go to depositor
        vm.prank(charlie);
        escrow.refundEscrow(id);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Refunded));
    }

    function test_refundNoFee() public {
        uint256 id = _createDefaultEscrow();
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.warp(block.timestamp + ONE_DAY + 1);

        vm.prank(alice);
        escrow.refundEscrow(id);

        // no fee on refund
        assertEq(usdc.balanceOf(treasury), treasuryBefore);
    }

    function test_revert_refundBeforeDeadline() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        vm.expectRevert();
        escrow.refundEscrow(id);
    }

    function test_revert_refundAlreadyReleased() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.releasePayment(id);

        vm.warp(block.timestamp + ONE_DAY + 1);

        vm.prank(alice);
        vm.expectRevert();
        escrow.refundEscrow(id);
    }

    // ─── Dispute ────────────────────────────────────────────────────────

    function test_disputeByDepositor() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.disputeEscrow(id);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Disputed));
    }

    function test_disputeByRecipient() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(bob);
        escrow.disputeEscrow(id);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Disputed));
    }

    function test_revert_disputeByStranger() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(charlie);
        vm.expectRevert();
        escrow.disputeEscrow(id);
    }

    function test_revert_disputeAlreadyReleased() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.releasePayment(id);

        vm.prank(alice);
        vm.expectRevert();
        escrow.disputeEscrow(id);
    }

    // ─── Resolve Dispute ────────────────────────────────────────────────

    function test_resolveDisputeToRecipient() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.disputeEscrow(id);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(owner);
        escrow.resolveDispute(id, true);

        uint256 fee = AMOUNT * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(bob) - bobBefore, AMOUNT - fee);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, fee);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Resolved));
    }

    function test_resolveDisputeToDepositor() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.disputeEscrow(id);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(owner);
        escrow.resolveDispute(id, false);

        assertEq(usdc.balanceOf(alice) - aliceBefore, AMOUNT);
        assertEq(usdc.balanceOf(treasury), treasuryBefore); // no fee on refund

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Resolved));
    }

    function test_revert_resolveNotOwner() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(alice);
        escrow.disputeEscrow(id);

        vm.prank(alice);
        vm.expectRevert();
        escrow.resolveDispute(id, true);
    }

    function test_revert_resolveNotDisputed() public {
        uint256 id = _createDefaultEscrow();

        vm.prank(owner);
        vm.expectRevert();
        escrow.resolveDispute(id, true);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setPlatformFeeBps() public {
        vm.prank(owner);
        escrow.setPlatformFeeBps(100); // 1%

        assertEq(escrow.platformFeeBps(), 100);
    }

    function test_revert_setFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.FeeTooHigh.selector, 1001));
        escrow.setPlatformFeeBps(1001);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        escrow.setTreasury(newTreasury);

        assertEq(escrow.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentEscrow.ZeroAddress.selector);
        escrow.setTreasury(address(0));
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        escrow.pause();

        vm.prank(alice);
        vm.expectRevert();
        escrow.createEscrow(bob, AMOUNT, _deadline());

        vm.prank(owner);
        escrow.unpause();

        // works again
        vm.prank(alice);
        escrow.createEscrow(bob, AMOUNT, _deadline());
    }

    // ─── Edge Cases ─────────────────────────────────────────────────────

    function test_releaseAfterDeadline() public {
        uint256 id = _createDefaultEscrow();

        vm.warp(block.timestamp + ONE_DAY + 1);

        // depositor can still release even after deadline (intentional)
        vm.prank(alice);
        escrow.releasePayment(id);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Released));
    }

    function test_revert_getEscrowInvalidId() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.EscrowNotFound.selector, 999));
        escrow.getEscrow(999);
    }

    function test_zeroFeeRelease() public {
        // deploy escrow with 0 fee
        AgentEscrow zeroFeeEscrow = new AgentEscrow(IERC20(address(usdc)), treasury, owner, 0);

        vm.prank(alice);
        usdc.approve(address(zeroFeeEscrow), type(uint256).max);

        vm.prank(alice);
        uint256 id = zeroFeeEscrow.createEscrow(bob, AMOUNT, _deadline());

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        zeroFeeEscrow.releasePayment(id);

        assertEq(usdc.balanceOf(bob) - bobBefore, AMOUNT);
        assertEq(usdc.balanceOf(treasury), treasuryBefore); // no fee
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_feeCalculation(uint256 amount) public {
        amount = bound(amount, 1_000_000, 1_000_000_000_000); // $1 to $1M

        usdc.mint(alice, amount);
        vm.prank(alice);
        usdc.approve(address(escrow), amount);

        vm.prank(alice);
        uint256 id = escrow.createEscrow(bob, amount, _deadline());

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        escrow.releasePayment(id);

        uint256 fee = amount * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(bob) - bobBefore, amount - fee);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, fee);
    }

    function testFuzz_refundReturnsFullAmount(uint256 amount) public {
        amount = bound(amount, 1_000_000, 1_000_000_000_000);

        usdc.mint(alice, amount);
        vm.prank(alice);
        usdc.approve(address(escrow), amount);

        vm.prank(alice);
        uint256 id = escrow.createEscrow(bob, amount, _deadline());

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.warp(block.timestamp + ONE_DAY + 1);
        vm.prank(alice);
        escrow.refundEscrow(id);

        assertEq(usdc.balanceOf(alice) - aliceBefore, amount);
    }

    function testFuzz_deadlineValidation(uint48 offset) public {
        offset = uint48(bound(offset, 1 hours, 90 days));

        vm.prank(alice);
        uint256 id = escrow.createEscrow(bob, AMOUNT, uint48(block.timestamp) + offset);

        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(IAgentEscrow.EscrowStatus.Active));
    }
}
