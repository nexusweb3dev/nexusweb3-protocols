// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentInsolvency} from "../src/AgentInsolvency.sol";
import {IAgentInsolvency} from "../src/interfaces/IAgentInsolvency.sol";

contract AgentInsolvencyTest is Test {
    ERC20Mock usdc;
    AgentInsolvency insolvency;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // debtor agent
    address bob = makeAddr("bob"); // creditor
    address charlie = makeAddr("charlie"); // creditor 2
    address dave = makeAddr("dave");

    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS = 10_000;
    uint256 constant REG_FEE = 0.001 ether;
    uint256 constant DEBT_AMT = 1_000_000_000; // $1000 USDC (6 decimals)
    uint48 constant ONE_DAY = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        insolvency = new AgentInsolvency(IERC20(address(usdc)), treasury, owner, FEE_BPS, REG_FEE);

        usdc.mint(alice, 100_000_000_000); // $100K
        usdc.mint(bob, 10_000_000_000);
        usdc.mint(charlie, 10_000_000_000);

        vm.prank(alice);
        usdc.approve(address(insolvency), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(insolvency), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(insolvency), type(uint256).max);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _dueDate() internal view returns (uint48) {
        return uint48(block.timestamp) + ONE_DAY;
    }

    function _registerDebt(address debtor, address creditor, uint256 amount) internal returns (uint256) {
        vm.prank(debtor);
        return insolvency.registerDebt{value: REG_FEE}(creditor, amount, _dueDate(), "test debt");
    }

    function _registerAndConfirm(address debtor, address creditor, uint256 amount) internal returns (uint256) {
        uint256 id = _registerDebt(debtor, creditor, amount);
        vm.prank(creditor);
        insolvency.confirmDebt(id);
        return id;
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(insolvency.paymentToken()), address(usdc));
        assertEq(insolvency.treasury(), treasury);
        assertEq(insolvency.owner(), owner);
        assertEq(insolvency.platformFeeBps(), FEE_BPS);
        assertEq(insolvency.registrationFee(), REG_FEE);
        assertEq(insolvency.debtCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentInsolvency.ZeroAddress.selector);
        new AgentInsolvency(IERC20(address(0)), treasury, owner, FEE_BPS, REG_FEE);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentInsolvency.ZeroAddress.selector);
        new AgentInsolvency(IERC20(address(usdc)), address(0), owner, FEE_BPS, REG_FEE);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.FeeTooHigh.selector, 1001));
        new AgentInsolvency(IERC20(address(usdc)), treasury, owner, 1001, REG_FEE);
    }

    // ─── Register Debt ──────────────────────────────────────────────────

    function test_registerDebt() public {
        uint256 id = _registerDebt(alice, bob, DEBT_AMT);

        assertEq(id, 0);
        assertEq(insolvency.debtCount(), 1);

        IAgentInsolvency.Debt memory d = insolvency.getDebt(id);
        assertEq(d.debtor, alice);
        assertEq(d.creditor, bob);
        assertEq(d.originalAmount, DEBT_AMT);
        assertEq(d.remainingAmount, DEBT_AMT);
        assertEq(d.dueDate, _dueDate());
        assertFalse(d.confirmed);
        assertFalse(d.resolved);
    }

    function test_registerDebt_accumulatesEthFee() public {
        _registerDebt(alice, bob, DEBT_AMT);
        assertEq(insolvency.accumulatedEthFees(), REG_FEE);
    }

    function test_registerMultipleDebts() public {
        uint256 id0 = _registerDebt(alice, bob, DEBT_AMT);
        uint256 id1 = _registerDebt(alice, charlie, DEBT_AMT / 2);

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(insolvency.debtCount(), 2);
        assertEq(insolvency.getDebtCount(alice), 2);
    }

    function test_revert_registerZeroCreditor() public {
        vm.prank(alice);
        vm.expectRevert(IAgentInsolvency.ZeroAddress.selector);
        insolvency.registerDebt{value: REG_FEE}(address(0), DEBT_AMT, _dueDate(), "test");
    }

    function test_revert_registerSelfDebt() public {
        vm.prank(alice);
        vm.expectRevert(IAgentInsolvency.SelfDebt.selector);
        insolvency.registerDebt{value: REG_FEE}(alice, DEBT_AMT, _dueDate(), "test");
    }

    function test_revert_registerZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IAgentInsolvency.InvalidAmount.selector);
        insolvency.registerDebt{value: REG_FEE}(bob, 0, _dueDate(), "test");
    }

    function test_revert_registerPastDueDate() public {
        vm.prank(alice);
        vm.expectRevert(IAgentInsolvency.InvalidDueDate.selector);
        insolvency.registerDebt{value: REG_FEE}(bob, DEBT_AMT, uint48(block.timestamp), "test");
    }

    function test_revert_registerEmptyDescription() public {
        vm.prank(alice);
        vm.expectRevert(IAgentInsolvency.EmptyDescription.selector);
        insolvency.registerDebt{value: REG_FEE}(bob, DEBT_AMT, _dueDate(), "");
    }

    function test_revert_registerInsufficientFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.InsufficientFee.selector, REG_FEE, 0));
        insolvency.registerDebt(bob, DEBT_AMT, _dueDate(), "test");
    }

    function test_revert_registerWhenPaused() public {
        vm.prank(owner);
        insolvency.pause();

        vm.prank(alice);
        vm.expectRevert();
        insolvency.registerDebt{value: REG_FEE}(bob, DEBT_AMT, _dueDate(), "test");
    }

    function test_revert_registerWhenInsolvent() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);
        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.AlreadyInsolvent.selector, alice));
        insolvency.registerDebt{value: REG_FEE}(charlie, DEBT_AMT, _dueDate(), "test");
    }

    // ─── Confirm Debt ───────────────────────────────────────────────────

    function test_confirmDebt() public {
        uint256 id = _registerDebt(alice, bob, DEBT_AMT);

        vm.prank(bob);
        insolvency.confirmDebt(id);

        IAgentInsolvency.Debt memory d = insolvency.getDebt(id);
        assertTrue(d.confirmed);
    }

    function test_revert_confirmNotCreditor() public {
        uint256 id = _registerDebt(alice, bob, DEBT_AMT);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NotCreditor.selector, id));
        insolvency.confirmDebt(id);
    }

    function test_revert_confirmAlreadyConfirmed() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtAlreadyConfirmed.selector, id));
        insolvency.confirmDebt(id);
    }

    function test_revert_confirmInvalidDebtId() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtNotFound.selector, 999));
        insolvency.confirmDebt(999);
    }

    // ─── Repay Debt ─────────────────────────────────────────────────────

    function test_repayDebtFully() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT);

        uint256 fee = DEBT_AMT * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(bob) - bobBefore, DEBT_AMT - fee);

        IAgentInsolvency.Debt memory d = insolvency.getDebt(id);
        assertEq(d.remainingAmount, 0);
        assertTrue(d.resolved);
    }

    function test_repayDebtPartially() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);
        uint256 half = DEBT_AMT / 2;

        vm.prank(alice);
        insolvency.repayDebt(id, half);

        IAgentInsolvency.Debt memory d = insolvency.getDebt(id);
        assertEq(d.remainingAmount, DEBT_AMT - half);
        assertFalse(d.resolved);
    }

    function test_repayDebt_feeAccumulation() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT);

        uint256 fee = DEBT_AMT * FEE_BPS / BPS;
        assertEq(insolvency.accumulatedUsdcFees(), fee);
    }

    function test_revert_repayNotDebtor() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NotDebtor.selector, id));
        insolvency.repayDebt(id, DEBT_AMT);
    }

    function test_revert_repayUnconfirmed() public {
        uint256 id = _registerDebt(alice, bob, DEBT_AMT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtNotConfirmed.selector, id));
        insolvency.repayDebt(id, DEBT_AMT);
    }

    function test_revert_repayResolved() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtAlreadyResolved.selector, id));
        insolvency.repayDebt(id, 1);
    }

    function test_revert_repayZero() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        vm.expectRevert(IAgentInsolvency.InvalidAmount.selector);
        insolvency.repayDebt(id, 0);
    }

    function test_revert_repayExceedsDebt() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentInsolvency.RepaymentExceedsDebt.selector, id, DEBT_AMT + 1, DEBT_AMT)
        );
        insolvency.repayDebt(id, DEBT_AMT + 1);
    }

    // ─── Declare Insolvency ─────────────────────────────────────────────

    function test_declareInsolvency_bySelf() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 500_000_000); // deposit $500

        assertTrue(insolvency.isInsolvent(alice));
        assertEq(insolvency.getTotalConfirmedDebt(alice), DEBT_AMT);

        uint256 deposit = 500_000_000;
        uint256 fee = deposit * FEE_BPS / BPS;
        assertEq(insolvency.getInsolvencyPool(alice), deposit - fee);
    }

    function test_declareInsolvency_byOwner() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        // owner must have USDC and approval to deposit on behalf
        usdc.mint(owner, 500_000_000);
        vm.prank(owner);
        usdc.approve(address(insolvency), type(uint256).max);

        vm.prank(owner);
        insolvency.declareInsolvency(alice, 500_000_000);

        assertTrue(insolvency.isInsolvent(alice));
    }

    function test_declareInsolvency_zeroDeposit() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        assertTrue(insolvency.isInsolvent(alice));
        assertEq(insolvency.getInsolvencyPool(alice), 0);
    }

    function test_declareInsolvency_permanent() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        // can't undeclare — there is no function for it
        assertTrue(insolvency.isInsolvent(alice));
    }

    function test_declareInsolvency_excludesUnconfirmedDebts() public {
        _registerAndConfirm(alice, bob, DEBT_AMT); // confirmed
        _registerDebt(alice, charlie, DEBT_AMT); // NOT confirmed

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        // only confirmed debt counted
        assertEq(insolvency.getTotalConfirmedDebt(alice), DEBT_AMT);
    }

    function test_declareInsolvency_excludesResolvedDebts() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);
        _registerAndConfirm(alice, charlie, DEBT_AMT);

        // repay first debt fully
        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        assertEq(insolvency.getTotalConfirmedDebt(alice), DEBT_AMT);
    }

    function test_revert_declareByStranger() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NotDebtorOrOwner.selector, alice, charlie));
        insolvency.declareInsolvency(alice, 0);
    }

    function test_revert_declareAlreadyInsolvent() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.AlreadyInsolvent.selector, alice));
        insolvency.declareInsolvency(alice, 0);
    }

    // ─── Claim Insolvency Payout ────────────────────────────────────────

    function test_claimInsolvencyPayout() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        uint256 deposit = 500_000_000; // $500
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;
        // single creditor with 100% of debt gets 100% of pool
        assertEq(usdc.balanceOf(bob) - bobBefore, pool);
    }

    function test_claimInsolvencyPayout_proportional_twoCreditors() public {
        uint256 id0 = _registerAndConfirm(alice, bob, 600_000_000); // $600
        uint256 id1 = _registerAndConfirm(alice, charlie, 400_000_000); // $400

        uint256 deposit = 500_000_000; // $500 to distribute
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;
        uint256 totalDebt = 1_000_000_000;

        // bob claims: 600/1000 of pool
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id0);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;
        assertEq(bobPayout, uint256(600_000_000) * pool / totalDebt);

        // charlie claims: 400/1000 of pool
        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        insolvency.claimInsolvencyPayout(alice, id1);
        uint256 charliePayout = usdc.balanceOf(charlie) - charlieBefore;
        assertEq(charliePayout, uint256(400_000_000) * pool / totalDebt);

        // order doesn't matter — both get correct proportional share
        assertEq(bobPayout + charliePayout, pool);
    }

    function test_claimInsolvencyPayout_multipleDebtsPerCreditor() public {
        // bob has two debts against alice
        uint256 id0 = _registerAndConfirm(alice, bob, 300_000_000);
        uint256 id1 = _registerAndConfirm(alice, bob, 200_000_000);
        _registerAndConfirm(alice, charlie, 500_000_000);

        uint256 deposit = 1_000_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;
        uint256 totalDebt = 1_000_000_000;

        // bob claims both debts separately
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id0);
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id1);
        uint256 bobTotal = usdc.balanceOf(bob) - bobBefore;

        // bob should get 500/1000 of pool (300 + 200)
        assertEq(bobTotal, uint256(500_000_000) * pool / totalDebt);
    }

    function test_revert_claimNotInsolvent() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NotInsolvent.selector, alice));
        insolvency.claimInsolvencyPayout(alice, id);
    }

    function test_revert_claimNotCreditor() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 500_000_000);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NotCreditor.selector, id));
        insolvency.claimInsolvencyPayout(alice, id);
    }

    function test_revert_claimUnconfirmed() public {
        uint256 id = _registerDebt(alice, bob, DEBT_AMT);
        _registerAndConfirm(alice, charlie, DEBT_AMT); // need at least one confirmed

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 500_000_000);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtNotConfirmed.selector, id));
        insolvency.claimInsolvencyPayout(alice, id);
    }

    function test_revert_claimAlreadyResolved() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 500_000_000);

        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtAlreadyResolved.selector, id));
        insolvency.claimInsolvencyPayout(alice, id);
    }

    function test_revert_claimNoPool() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0); // zero deposit

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NoAssetsToDistribute.selector, alice));
        insolvency.claimInsolvencyPayout(alice, id);
    }

    // ─── Process Insolvency Payout (batch) ──────────────────────────────

    function test_processInsolvencyPayout_batch() public {
        uint256 id0 = _registerAndConfirm(alice, bob, 600_000_000);
        uint256 id1 = _registerAndConfirm(alice, charlie, 400_000_000);

        uint256 deposit = 1_000_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;
        uint256 totalDebt = 1_000_000_000;

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 charlieBefore = usdc.balanceOf(charlie);

        insolvency.processInsolvencyPayout(alice);

        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;
        uint256 charliePayout = usdc.balanceOf(charlie) - charlieBefore;

        assertEq(bobPayout, uint256(600_000_000) * pool / totalDebt);
        assertEq(charliePayout, uint256(400_000_000) * pool / totalDebt);

        // all debts resolved
        assertTrue(insolvency.getDebt(id0).resolved);
        assertTrue(insolvency.getDebt(id1).resolved);
    }

    function test_processInsolvencyPayout_skipsUnconfirmed() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);
        _registerDebt(alice, charlie, DEBT_AMT); // NOT confirmed

        uint256 deposit = 500_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 charlieBefore = usdc.balanceOf(charlie);

        insolvency.processInsolvencyPayout(alice);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;

        // bob gets 100% since charlie's debt is unconfirmed
        assertEq(usdc.balanceOf(bob) - bobBefore, pool);
        assertEq(usdc.balanceOf(charlie) - charlieBefore, 0);
    }

    function test_revert_processNotInsolvent() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NotInsolvent.selector, alice));
        insolvency.processInsolvencyPayout(alice);
    }

    function test_revert_processNoPool() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NoAssetsToDistribute.selector, alice));
        insolvency.processInsolvencyPayout(alice);
    }

    function test_revert_processNoPendingClaims() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        uint256 deposit = 500_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        // claim individually first
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id);

        // batch has nothing left
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.NoPendingClaims.selector, alice));
        insolvency.processInsolvencyPayout(alice);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees_eth() public {
        _registerDebt(alice, bob, DEBT_AMT);

        uint256 treasuryBefore = treasury.balance;
        insolvency.collectFees();
        assertEq(treasury.balance - treasuryBefore, REG_FEE);
    }

    function test_collectFees_usdc() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);

        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT);

        uint256 fee = DEBT_AMT * FEE_BPS / BPS;
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // collect both ETH and USDC fees
        insolvency.collectFees();

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, fee);
    }

    function test_collectFees_bothTypes() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);
        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT);

        uint256 treasuryEthBefore = treasury.balance;
        uint256 treasuryUsdcBefore = usdc.balanceOf(treasury);

        insolvency.collectFees();

        assertGt(treasury.balance - treasuryEthBefore, 0);
        assertGt(usdc.balanceOf(treasury) - treasuryUsdcBefore, 0);
        assertEq(insolvency.accumulatedEthFees(), 0);
        assertEq(insolvency.accumulatedUsdcFees(), 0);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentInsolvency.NoFeesToCollect.selector);
        insolvency.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setPlatformFeeBps() public {
        vm.prank(owner);
        insolvency.setPlatformFeeBps(200);
        assertEq(insolvency.platformFeeBps(), 200);
    }

    function test_revert_setFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.FeeTooHigh.selector, 1001));
        insolvency.setPlatformFeeBps(1001);
    }

    function test_revert_setFeeNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        insolvency.setPlatformFeeBps(200);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        insolvency.setTreasury(newTreasury);
        assertEq(insolvency.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentInsolvency.ZeroAddress.selector);
        insolvency.setTreasury(address(0));
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        insolvency.pause();

        vm.prank(alice);
        vm.expectRevert();
        insolvency.registerDebt{value: REG_FEE}(bob, DEBT_AMT, _dueDate(), "test");

        vm.prank(owner);
        insolvency.unpause();

        _registerDebt(alice, bob, DEBT_AMT); // works again
    }

    // ─── View Functions ─────────────────────────────────────────────────

    function test_getSolvencyStatus_solvent() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        IAgentInsolvency.SolvencyStatus memory s = insolvency.getSolvencyStatus(alice);
        assertEq(s.totalDebts, DEBT_AMT);
        assertTrue(s.isSolvent);
    }

    function test_getSolvencyStatus_insolvent() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        uint256 deposit = 500_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        IAgentInsolvency.SolvencyStatus memory s = insolvency.getSolvencyStatus(alice);
        assertFalse(s.isSolvent);
        uint256 fee = deposit * FEE_BPS / BPS;
        assertEq(s.poolBalance, deposit - fee);
    }

    function test_getDebts() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);
        _registerDebt(alice, charlie, DEBT_AMT / 2);

        IAgentInsolvency.Debt[] memory debts = insolvency.getDebts(alice);
        assertEq(debts.length, 2);
        assertEq(debts[0].creditor, bob);
        assertEq(debts[1].creditor, charlie);
        assertTrue(debts[0].confirmed);
        assertFalse(debts[1].confirmed);
    }

    function test_getCreditors() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);
        _registerAndConfirm(alice, charlie, DEBT_AMT / 2);
        _registerAndConfirm(alice, bob, DEBT_AMT / 4); // duplicate creditor

        address[] memory creditors = insolvency.getCreditors(alice);
        assertEq(creditors.length, 2); // deduplicated
        assertEq(creditors[0], bob);
        assertEq(creditors[1], charlie);
    }

    function test_getCreditors_excludesResolved() public {
        uint256 id = _registerAndConfirm(alice, bob, DEBT_AMT);
        _registerAndConfirm(alice, charlie, DEBT_AMT / 2);

        vm.prank(alice);
        insolvency.repayDebt(id, DEBT_AMT); // fully repay bob's debt

        address[] memory creditors = insolvency.getCreditors(alice);
        assertEq(creditors.length, 1);
        assertEq(creditors[0], charlie);
    }

    function test_getTotalPaidOut() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        uint256 deposit = 500_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        assertEq(insolvency.getTotalPaidOut(alice), 0);

        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, 0);

        assertGt(insolvency.getTotalPaidOut(alice), 0);
    }

    function test_revert_getDebtInvalidId() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.DebtNotFound.selector, 999));
        insolvency.getDebt(999);
    }

    // ─── Edge Cases ─────────────────────────────────────────────────────

    function test_proportionalMath_orderIndependent() public {
        // critical: claim order should not affect payout amounts
        uint256 id0 = _registerAndConfirm(alice, bob, 700_000_000);
        uint256 id1 = _registerAndConfirm(alice, charlie, 300_000_000);

        uint256 deposit = 500_000_000;
        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;

        // claim in reverse order (charlie first, then bob)
        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        insolvency.claimInsolvencyPayout(alice, id1);
        uint256 charliePayout = usdc.balanceOf(charlie) - charlieBefore;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id0);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;

        // payouts should be exact proportional regardless of order
        assertEq(charliePayout, uint256(300_000_000) * pool / 1_000_000_000);
        assertEq(bobPayout, uint256(700_000_000) * pool / 1_000_000_000);
    }

    function test_insolvencyFeeOnSettlement() public {
        _registerAndConfirm(alice, bob, DEBT_AMT);

        uint256 deposit = 1_000_000_000;
        uint256 usdcFeesBefore = insolvency.accumulatedUsdcFees();

        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 fee = deposit * FEE_BPS / BPS;
        assertEq(insolvency.accumulatedUsdcFees() - usdcFeesBefore, fee);
    }

    function test_excessEthReturnsCorrectFee() public {
        // overpay registration fee
        vm.prank(alice);
        insolvency.registerDebt{value: 0.01 ether}(bob, DEBT_AMT, _dueDate(), "overpaid");

        // entire msg.value is accumulated (no refund — by design)
        assertEq(insolvency.accumulatedEthFees(), 0.01 ether);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_repayFeeCalculation(uint256 amount) public {
        amount = bound(amount, 1_000_000, 1_000_000_000_000); // $1 to $1M

        usdc.mint(alice, amount);

        uint256 id = _registerAndConfirm(alice, bob, amount);

        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(alice);
        insolvency.repayDebt(id, amount);

        uint256 fee = amount * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(bob) - bobBefore, amount - fee);
    }

    function testFuzz_proportionalPayoutSumsCorrectly(uint256 bobDebt, uint256 charlieDebt) public {
        bobDebt = bound(bobDebt, 1_000_000, 500_000_000_000);
        charlieDebt = bound(charlieDebt, 1_000_000, 500_000_000_000);

        uint256 deposit = 1_000_000_000;
        usdc.mint(alice, deposit + 10 ether);

        uint256 id0 = _registerAndConfirm(alice, bob, bobDebt);
        uint256 id1 = _registerAndConfirm(alice, charlie, charlieDebt);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 fee = deposit * FEE_BPS / BPS;
        uint256 pool = deposit - fee;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id0);

        uint256 charlieBefore = usdc.balanceOf(charlie);
        vm.prank(charlie);
        insolvency.claimInsolvencyPayout(alice, id1);

        uint256 totalPaid = (usdc.balanceOf(bob) - bobBefore) + (usdc.balanceOf(charlie) - charlieBefore);

        // total paid should never exceed pool (floor rounding guarantees this)
        assertLe(totalPaid, pool);
        // dust should be minimal (at most 1 unit per creditor)
        assertGe(totalPaid, pool - 2);
    }

    function testFuzz_registrationRequiresMinFee(uint256 ethSent) public {
        ethSent = bound(ethSent, 0, REG_FEE - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentInsolvency.InsufficientFee.selector, REG_FEE, ethSent));
        insolvency.registerDebt{value: ethSent}(bob, DEBT_AMT, _dueDate(), "test");
    }

    function testFuzz_insolvencyPoolNeverExceeded(uint256 deposit, uint256 debtAmt) public {
        deposit = bound(deposit, 1_000_000, 1_000_000_000_000);
        debtAmt = bound(debtAmt, 1_000_000, 1_000_000_000_000);

        usdc.mint(alice, deposit);

        uint256 id = _registerAndConfirm(alice, bob, debtAmt);

        vm.prank(alice);
        insolvency.declareInsolvency(alice, deposit);

        uint256 pool = insolvency.getInsolvencyPool(alice);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        insolvency.claimInsolvencyPayout(alice, id);
        uint256 payout = usdc.balanceOf(bob) - bobBefore;

        // payout should never exceed pool
        assertLe(payout, pool);
    }
}
