// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentSplit} from "../src/AgentSplit.sol";
import {IAgentSplit} from "../src/interfaces/IAgentSplit.sol";

contract AgentSplitTest is Test {
    ERC20Mock usdc;
    AgentSplit split;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address payer = makeAddr("payer");

    uint256 constant FEE_BPS = 50; // 0.5%
    uint256 constant BPS = 10_000;
    uint256 constant CREATE_FEE = 0.001 ether;

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        split = new AgentSplit(IERC20(address(usdc)), treasury, owner, FEE_BPS, CREATE_FEE);

        vm.deal(alice, 10 ether);
        usdc.mint(payer, 10_000_000_000); // $10K
        vm.prank(payer);
        usdc.approve(address(split), type(uint256).max);
    }

    function _twoWay() internal returns (address[] memory r, uint256[] memory s) {
        r = new address[](2);
        s = new uint256[](2);
        r[0] = makeAddr("bob");
        r[1] = makeAddr("charlie");
        s[0] = 6000; // 60%
        s[1] = 4000; // 40%
    }

    function _createDefault() internal returns (uint256) {
        (address[] memory r, uint256[] memory s) = _twoWay();
        vm.prank(alice);
        return split.createSplit{value: CREATE_FEE}(r, s, "Team split");
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(split.treasury(), treasury);
        assertEq(split.platformFeeBps(), FEE_BPS);
        assertEq(split.creationFee(), CREATE_FEE);
        assertEq(split.splitCount(), 0);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentSplit.ZeroAddress.selector);
        new AgentSplit(IERC20(address(0)), treasury, owner, FEE_BPS, CREATE_FEE);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.FeeTooHigh.selector, 1001));
        new AgentSplit(IERC20(address(usdc)), treasury, owner, 1001, CREATE_FEE);
    }

    // ─── Create ─────────────────────────────────────────────────────────

    function test_createSplit() public {
        uint256 id = _createDefault();
        assertEq(id, 0);
        assertEq(split.splitCount(), 1);

        IAgentSplit.Split memory s = split.getSplit(id);
        assertEq(s.splitOwner, alice);
        assertEq(s.recipients.length, 2);
        assertEq(s.shares[0], 6000);
        assertEq(s.shares[1], 4000);
        assertTrue(s.active);
    }

    function test_createCollectsFee() public {
        _createDefault();
        assertEq(split.accumulatedEthFees(), CREATE_FEE);
    }

    function test_revert_createEmptyDescription() public {
        (address[] memory r, uint256[] memory s) = _twoWay();
        vm.prank(alice);
        vm.expectRevert(IAgentSplit.EmptyDescription.selector);
        split.createSplit{value: CREATE_FEE}(r, s, "");
    }

    function test_revert_createNoRecipients() public {
        address[] memory r = new address[](0);
        uint256[] memory s = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(IAgentSplit.NoRecipients.selector);
        split.createSplit{value: CREATE_FEE}(r, s, "empty");
    }

    function test_revert_createSharesMismatch() public {
        address[] memory r = new address[](2);
        uint256[] memory s = new uint256[](1);
        r[0] = bob; r[1] = charlie;
        s[0] = 10000;
        vm.prank(alice);
        vm.expectRevert(IAgentSplit.InvalidShares.selector);
        split.createSplit{value: CREATE_FEE}(r, s, "bad");
    }

    function test_revert_createSharesNotTotal() public {
        address[] memory r = new address[](2);
        uint256[] memory s = new uint256[](2);
        r[0] = bob; r[1] = charlie;
        s[0] = 5000; s[1] = 3000; // total 8000, not 10000
        vm.prank(alice);
        vm.expectRevert(IAgentSplit.InvalidShares.selector);
        split.createSplit{value: CREATE_FEE}(r, s, "bad shares");
    }

    function test_revert_createDuplicateRecipient() public {
        address[] memory r = new address[](2);
        uint256[] memory s = new uint256[](2);
        r[0] = bob; r[1] = bob;
        s[0] = 5000; s[1] = 5000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.DuplicateRecipient.selector, bob));
        split.createSplit{value: CREATE_FEE}(r, s, "dupe");
    }

    function test_revert_createZeroShare() public {
        address[] memory r = new address[](2);
        uint256[] memory s = new uint256[](2);
        r[0] = bob; r[1] = charlie;
        s[0] = 10000; s[1] = 0;
        vm.prank(alice);
        vm.expectRevert(IAgentSplit.InvalidShares.selector);
        split.createSplit{value: CREATE_FEE}(r, s, "zero share");
    }

    function test_revert_createInsufficientFee() public {
        (address[] memory r, uint256[] memory s) = _twoWay();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.InsufficientFee.selector, CREATE_FEE, 0));
        split.createSplit(r, s, "no fee");
    }

    // ─── Receive Payment ────────────────────────────────────────────────

    function test_receivePayment() public {
        uint256 id = _createDefault();
        (address[] memory r,) = _twoWay();

        uint256 amount = 1_000_000_000; // $1000
        uint256 fee = amount * FEE_BPS / BPS; // $5
        uint256 dist = amount - fee; // $995

        uint256 bobBefore = usdc.balanceOf(r[0]);
        uint256 charBefore = usdc.balanceOf(r[1]);

        vm.prank(payer);
        split.receivePayment(id, amount);

        // bob: 60% of $995 = $597
        assertEq(usdc.balanceOf(r[0]) - bobBefore, dist * 6000 / 10000);
        // charlie: 40% of $995 = $398
        assertEq(usdc.balanceOf(r[1]) - charBefore, dist * 4000 / 10000);
        assertEq(split.accumulatedUsdcFees(), fee);
    }

    function test_receivePaymentUpdatesTotalReceived() public {
        uint256 id = _createDefault();

        vm.prank(payer);
        split.receivePayment(id, 500_000_000);

        vm.prank(payer);
        split.receivePayment(id, 300_000_000);

        assertEq(split.getSplit(id).totalReceived, 800_000_000);
    }

    function test_revert_receiveZeroAmount() public {
        uint256 id = _createDefault();
        vm.prank(payer);
        vm.expectRevert(IAgentSplit.ZeroAmount.selector);
        split.receivePayment(id, 0);
    }

    function test_revert_receiveInactiveSplit() public {
        uint256 id = _createDefault();
        vm.prank(alice);
        split.deactivateSplit(id);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.SplitNotActive.selector, id));
        split.receivePayment(id, 1_000_000);
    }

    // ─── Update Shares ──────────────────────────────────────────────────

    function test_updateShares() public {
        uint256 id = _createDefault();

        address[] memory newR = new address[](3);
        uint256[] memory newS = new uint256[](3);
        newR[0] = bob; newR[1] = charlie; newR[2] = makeAddr("dave");
        newS[0] = 3000; newS[1] = 3000; newS[2] = 4000;

        vm.prank(alice);
        split.updateShares(id, newR, newS);

        (address[] memory r, uint256[] memory s) = split.getRecipients(id);
        assertEq(r.length, 3);
        assertEq(s[2], 4000);
    }

    function test_revert_updateSharesNotOwner() public {
        uint256 id = _createDefault();
        (address[] memory r, uint256[] memory s) = _twoWay();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.NotSplitOwner.selector, id));
        split.updateShares(id, r, s);
    }

    // ─── Deactivate ─────────────────────────────────────────────────────

    function test_deactivateSplit() public {
        uint256 id = _createDefault();

        vm.prank(alice);
        split.deactivateSplit(id);

        assertFalse(split.getSplit(id).active);
    }

    function test_revert_deactivateNotOwner() public {
        uint256 id = _createDefault();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.NotSplitOwner.selector, id));
        split.deactivateSplit(id);
    }

    // ─── Claim ──────────────────────────────────────────────────────────

    function test_revert_claimNothing() public {
        vm.prank(bob);
        vm.expectRevert(IAgentSplit.NothingToClaim.selector);
        split.claimFailed();
    }

    function test_getClaimableZero() public view {
        assertEq(split.getClaimable(bob), 0);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        uint256 id = _createDefault();

        vm.prank(payer);
        split.receivePayment(id, 1_000_000_000);

        uint256 ethBefore = treasury.balance;
        uint256 usdcBefore = usdc.balanceOf(treasury);
        split.collectFees();

        assertEq(treasury.balance - ethBefore, CREATE_FEE);
        uint256 expectedUsdcFee = 1_000_000_000 * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(treasury) - usdcBefore, expectedUsdcFee);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentSplit.NoFeesToCollect.selector);
        split.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setPlatformFeeBps() public {
        vm.prank(owner);
        split.setPlatformFeeBps(100);
        assertEq(split.platformFeeBps(), 100);
    }

    function test_revert_setFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.FeeTooHigh.selector, 1001));
        split.setPlatformFeeBps(1001);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        split.setTreasury(newT);
        assertEq(split.treasury(), newT);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentSplit.ZeroAddress.selector);
        split.setTreasury(address(0));
    }

    function test_revert_getSplitNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentSplit.SplitNotFound.selector, 999));
        split.getSplit(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_paymentDistribution(uint256 amount) public {
        amount = bound(amount, 1_000_000, 5_000_000_000);
        uint256 id = _createDefault();
        (address[] memory r,) = _twoWay();

        uint256 bobBefore = usdc.balanceOf(r[0]);

        vm.prank(payer);
        split.receivePayment(id, amount);

        uint256 fee = amount * FEE_BPS / BPS;
        uint256 dist = amount - fee;
        uint256 bobExpected = dist * 6000 / 10000;
        assertEq(usdc.balanceOf(r[0]) - bobBefore, bobExpected);
    }

    function testFuzz_threeWaySplit(uint256 s1, uint256 s2) public {
        s1 = bound(s1, 1000, 5000);
        s2 = bound(s2, 1000, 5000);
        uint256 s3 = 10000 - s1 - s2;
        vm.assume(s3 >= 1000);

        address[] memory r = new address[](3);
        uint256[] memory sh = new uint256[](3);
        r[0] = makeAddr("a"); r[1] = makeAddr("b"); r[2] = makeAddr("c");
        sh[0] = s1; sh[1] = s2; sh[2] = s3;

        vm.prank(alice);
        uint256 id = split.createSplit{value: CREATE_FEE}(r, sh, "fuzz");

        vm.prank(payer);
        split.receivePayment(id, 10_000_000_000); // $10K

        // all shares accounted for (no USDC stuck in contract, minus rounding dust)
        uint256 inContract = usdc.balanceOf(address(split));
        assertLe(inContract, split.accumulatedUsdcFees() + 3); // max 3 wei rounding
    }
}
