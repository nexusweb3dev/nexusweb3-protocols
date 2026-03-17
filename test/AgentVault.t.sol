// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AgentVaultFactory} from "../src/AgentVaultFactory.sol";
import {IAgentVault} from "../src/interfaces/IAgentVault.sol";

contract AgentVaultTest is Test {
    ERC20Mock token;
    AgentVault vault;
    AgentVaultFactory factory;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");
    address feeCollector = makeAddr("feeCollector");

    uint256 constant FEE_BPS = 10; // 0.1%
    uint256 constant BPS = 10_000;
    uint256 constant INITIAL_BALANCE = 100_000e18;

    function setUp() public {
        token = new ERC20Mock("Test Token", "TEST", 18);
        factory = new AgentVaultFactory(deployer, feeCollector, FEE_BPS);

        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);

        vm.prank(alice);
        address vaultAddr = factory.createVault(IERC20(address(token)), "Agent Vault TEST", "avTEST", bytes32("salt1"));
        vault = AgentVault(vaultAddr);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    // ─── Constructor / Factory ──────────────────────────────────────────

    function test_factoryDeploysVault() public view {
        assertEq(vault.owner(), alice);
        assertEq(vault.feeRecipient(), feeCollector);
        assertEq(vault.protocolFeeBps(), FEE_BPS);
        assertEq(vault.asset(), address(token));
        assertEq(vault.name(), "Agent Vault TEST");
        assertEq(vault.symbol(), "avTEST");
    }

    function test_factoryTracksVaults() public view {
        address[] memory vaults = factory.getDeployedVaults();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], address(vault));

        address[] memory aliceVaults = factory.getVaultsByOwner(alice);
        assertEq(aliceVaults.length, 1);
        assertEq(aliceVaults[0], address(vault));
    }

    function test_factoryCreateMultipleVaults() public {
        vm.prank(bob);
        address v2 = factory.createVault(IERC20(address(token)), "Vault 2", "v2", bytes32("salt2"));

        assertEq(factory.deployedVaultCount(), 2);
        assertEq(factory.getVaultsByOwner(bob).length, 1);
        assertEq(AgentVault(v2).owner(), bob);
    }

    function test_revert_duplicateSalt() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.createVault(IERC20(address(token)), "Agent Vault TEST", "avTEST", bytes32("salt1"));
    }

    // ─── Deposit with Fee ───────────────────────────────────────────────

    function test_depositTakesFee() public {
        uint256 depositAmount = 10_000e18;
        uint256 expectedFee = depositAmount * FEE_BPS / BPS; // 10e18

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        assertEq(token.balanceOf(feeCollector), expectedFee);
        assertEq(vault.totalAssets(), depositAmount - expectedFee);
    }

    function test_depositSharesAccountForFee() public {
        uint256 depositAmount = 10_000e18;
        uint256 expectedFee = depositAmount * FEE_BPS / BPS;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // shares should be based on post-fee assets
        assertEq(shares, depositAmount - expectedFee);
    }

    function test_previewDepositMatchesActual() public {
        uint256 depositAmount = 10_000e18;

        uint256 previewShares = vault.previewDeposit(depositAmount);

        vm.prank(alice);
        uint256 actualShares = vault.deposit(depositAmount, alice);

        assertEq(previewShares, actualShares);
    }

    function test_previewMintAccountsForFee() public {
        uint256 shares = 5_000e18;
        uint256 assetsNeeded = vault.previewMint(shares);

        // assetsNeeded should be > shares because of fee
        assertGt(assetsNeeded, shares);

        uint256 expectedNet = assetsNeeded - (assetsNeeded * FEE_BPS / BPS);
        // the net assets after fee should produce at least `shares` shares
        assertGe(expectedNet, shares);
    }

    function test_depositZeroFeeWhenBpsZero() public {
        vm.prank(alice);
        vault.setProtocolFeeBps(0);

        uint256 depositAmount = 1_000e18;
        uint256 feeCollectorBefore = token.balanceOf(feeCollector);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        assertEq(token.balanceOf(feeCollector), feeCollectorBefore);
        assertEq(vault.totalAssets(), depositAmount);
    }

    // ─── Withdraw / Redeem ──────────────────────────────────────────────

    function test_withdrawAfterDeposit() public {
        uint256 depositAmount = 10_000e18;

        vm.startPrank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 fee = depositAmount * FEE_BPS / BPS;
        assertEq(withdrawn, depositAmount - fee);
    }

    // ─── Operator Management ────────────────────────────────────────────

    function test_addOperator() public {
        vm.prank(alice);
        vault.addOperator(operator1, 1_000e18);

        assertTrue(vault.isOperator(operator1));
        IAgentVault.OperatorConfig memory config = vault.getOperatorConfig(operator1);
        assertEq(config.spendingLimit, 1_000e18);
        assertEq(config.spent, 0);
    }

    function test_revert_addOperatorNotOwner() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.addOperator(operator1, 1_000e18);
    }

    function test_revert_addOperatorZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IAgentVault.ZeroAddress.selector);
        vault.addOperator(address(0), 1_000e18);
    }

    function test_revert_addDuplicateOperator() public {
        vm.startPrank(alice);
        vault.addOperator(operator1, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(IAgentVault.OperatorAlreadyExists.selector, operator1));
        vault.addOperator(operator1, 2_000e18);
        vm.stopPrank();
    }

    function test_removeOperator() public {
        vm.startPrank(alice);
        vault.addOperator(operator1, 1_000e18);
        vault.removeOperator(operator1);
        vm.stopPrank();

        assertFalse(vault.isOperator(operator1));
    }

    function test_revert_removeNonexistentOperator() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentVault.OperatorDoesNotExist.selector, operator1));
        vault.removeOperator(operator1);
    }

    function test_setSpendingLimit() public {
        vm.startPrank(alice);
        vault.addOperator(operator1, 1_000e18);
        vault.setSpendingLimit(operator1, 5_000e18);
        vm.stopPrank();

        IAgentVault.OperatorConfig memory config = vault.getOperatorConfig(operator1);
        assertEq(config.spendingLimit, 5_000e18);
    }

    function test_resetOperatorSpent() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vm.stopPrank();

        vm.prank(operator1);
        vault.operatorWithdraw(3_000e18, operator1);

        IAgentVault.OperatorConfig memory config = vault.getOperatorConfig(operator1);
        assertEq(config.spent, 3_000e18);

        vm.prank(alice);
        vault.resetOperatorSpent(operator1);

        config = vault.getOperatorConfig(operator1);
        assertEq(config.spent, 0);
    }

    // ─── Operator Withdraw ──────────────────────────────────────────────

    function test_operatorWithdraw() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vm.stopPrank();

        uint256 op1Before = token.balanceOf(operator1);

        vm.prank(operator1);
        vault.operatorWithdraw(2_000e18, operator1);

        assertEq(token.balanceOf(operator1) - op1Before, 2_000e18);

        IAgentVault.OperatorConfig memory config = vault.getOperatorConfig(operator1);
        assertEq(config.spent, 2_000e18);
    }

    function test_operatorWithdrawToThirdParty() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vm.stopPrank();

        address recipient = makeAddr("recipient");
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(operator1);
        vault.operatorWithdraw(1_000e18, recipient);

        assertEq(token.balanceOf(recipient) - recipientBefore, 1_000e18);
    }

    function test_revert_operatorExceedsLimit() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 1_000e18);
        vm.stopPrank();

        vm.prank(operator1);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentVault.SpendingLimitExceeded.selector, operator1, 1_001e18, 1_000e18)
        );
        vault.operatorWithdraw(1_001e18, operator1);
    }

    function test_revert_nonOperatorWithdraw() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAgentVault.NotOperator.selector, bob));
        vault.operatorWithdraw(1_000e18, bob);
    }

    function test_revert_operatorWithdrawZero() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vm.stopPrank();

        vm.prank(operator1);
        vm.expectRevert(IAgentVault.ZeroAmount.selector);
        vault.operatorWithdraw(0, operator1);
    }

    function test_revert_operatorWithdrawToZeroAddress() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vm.stopPrank();

        vm.prank(operator1);
        vm.expectRevert(IAgentVault.ZeroAddress.selector);
        vault.operatorWithdraw(1_000e18, address(0));
    }

    function test_multipleOperatorsIndependent() public {
        vm.startPrank(alice);
        vault.deposit(20_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vault.addOperator(operator2, 3_000e18);
        vm.stopPrank();

        vm.prank(operator1);
        vault.operatorWithdraw(4_000e18, operator1);

        vm.prank(operator2);
        vault.operatorWithdraw(2_000e18, operator2);

        IAgentVault.OperatorConfig memory c1 = vault.getOperatorConfig(operator1);
        IAgentVault.OperatorConfig memory c2 = vault.getOperatorConfig(operator2);
        assertEq(c1.spent, 4_000e18);
        assertEq(c2.spent, 2_000e18);
    }

    // ─── Pausable ───────────────────────────────────────────────────────

    function test_pauseBlocksDeposit() public {
        vm.prank(alice);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1_000e18, alice);
    }

    function test_pauseBlocksOperatorWithdraw() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vault.pause();
        vm.stopPrank();

        vm.prank(operator1);
        vm.expectRevert();
        vault.operatorWithdraw(1_000e18, operator1);
    }

    function test_unpauseResumesOperations() public {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        vault.addOperator(operator1, 5_000e18);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        vm.prank(operator1);
        vault.operatorWithdraw(1_000e18, operator1);
        assertEq(token.balanceOf(operator1), 1_000e18);
    }

    function test_withdrawWorksWhenPaused() public {
        vm.startPrank(alice);
        uint256 shares = vault.deposit(10_000e18, alice);
        vault.pause();

        // user can always exit even when paused
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(withdrawn, 0);
    }

    function test_revert_pauseNotOwner() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.pause();
    }

    // ─── Fee Configuration ──────────────────────────────────────────────

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newFeeRecipient");

        vm.prank(alice);
        vault.setFeeRecipient(newRecipient);

        assertEq(vault.feeRecipient(), newRecipient);
    }

    function test_revert_setFeeRecipientZero() public {
        vm.prank(alice);
        vm.expectRevert(IAgentVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_setProtocolFeeBps() public {
        vm.prank(alice);
        vault.setProtocolFeeBps(50); // 0.5%

        assertEq(vault.protocolFeeBps(), 50);
    }

    function test_revert_feeTooHigh() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAgentVault.FeeTooHigh.selector, 501));
        vault.setProtocolFeeBps(501);
    }

    // ─── Sweep ──────────────────────────────────────────────────────────

    function test_sweepRandomToken() public {
        ERC20Mock randomToken = new ERC20Mock("Random", "RND", 18);
        randomToken.mint(address(vault), 500e18);

        vm.prank(alice);
        vault.sweep(address(randomToken));

        assertEq(randomToken.balanceOf(alice), 500e18);
        assertEq(randomToken.balanceOf(address(vault)), 0);
    }

    function test_revert_sweepVaultAsset() public {
        vm.prank(alice);
        vm.expectRevert(IAgentVault.CannotSweepVaultAsset.selector);
        vault.sweep(address(token));
    }

    // ─── Factory Admin ──────────────────────────────────────────────────

    function test_factorySetDefaultFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(deployer);
        factory.setDefaultFeeRecipient(newRecipient);

        assertEq(factory.defaultFeeRecipient(), newRecipient);
    }

    function test_factorySetDefaultFeeBps() public {
        vm.prank(deployer);
        factory.setDefaultFeeBps(25);

        assertEq(factory.defaultFeeBps(), 25);
    }

    function test_revert_factoryFeeBpsTooHigh() public {
        vm.prank(deployer);
        vm.expectRevert();
        factory.setDefaultFeeBps(501);
    }

    function test_revert_zeroAssetConstructor() public {
        vm.expectRevert(IAgentVault.ZeroAddress.selector);
        new AgentVault(IERC20(address(0)), "Test", "T", alice, feeCollector, FEE_BPS);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_depositFeeIsCorrect(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e18, INITIAL_BALANCE);

        uint256 expectedFee = depositAmount * FEE_BPS / BPS;
        uint256 feeCollectorBefore = token.balanceOf(feeCollector);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 actualFee = token.balanceOf(feeCollector) - feeCollectorBefore;
        assertEq(actualFee, expectedFee);
    }

    function testFuzz_operatorCannotExceedLimit(uint128 limit, uint256 withdrawAmount) public {
        limit = uint128(bound(limit, 1e18, 50_000e18));
        withdrawAmount = bound(withdrawAmount, limit + 1, type(uint128).max);

        vm.startPrank(alice);
        vault.deposit(INITIAL_BALANCE, alice);
        vault.addOperator(operator1, limit);
        vm.stopPrank();

        vm.prank(operator1);
        vm.expectRevert();
        vault.operatorWithdraw(withdrawAmount, operator1);
    }

    function testFuzz_operatorWithdrawUpToLimit(uint128 limit, uint256 amount1, uint256 amount2) public {
        limit = uint128(bound(limit, 2e18, 50_000e18));
        amount1 = bound(amount1, 1, limit / 2);
        amount2 = bound(amount2, 1, limit / 2);

        vm.startPrank(alice);
        vault.deposit(INITIAL_BALANCE, alice);
        vault.addOperator(operator1, limit);
        vm.stopPrank();

        vm.startPrank(operator1);
        vault.operatorWithdraw(amount1, operator1);
        vault.operatorWithdraw(amount2, operator1);
        vm.stopPrank();

        IAgentVault.OperatorConfig memory config = vault.getOperatorConfig(operator1);
        assertEq(config.spent, amount1 + amount2);
    }

    function testFuzz_previewDepositMatchesDeposit(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e18, INITIAL_BALANCE);

        uint256 preview = vault.previewDeposit(depositAmount);

        vm.prank(alice);
        uint256 actual = vault.deposit(depositAmount, alice);

        assertEq(preview, actual);
    }

    function testFuzz_withdrawReturnsPostFeeAmount(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e18, INITIAL_BALANCE);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);
        uint256 withdrawn = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        uint256 expectedFee = depositAmount * FEE_BPS / BPS;
        assertEq(withdrawn, depositAmount - expectedFee);
    }
}
