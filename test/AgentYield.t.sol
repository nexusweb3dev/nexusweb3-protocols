// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentYield} from "../src/AgentYield.sol";
import {IAgentYield} from "../src/interfaces/IAgentYield.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

contract AgentYieldTest is Test {
    ERC20Mock usdc;
    MockAToken aUsdc;
    MockAavePool aavePool;
    AgentYield vault;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant FEE_BPS = 1000; // 10%
    uint256 constant BPS = 10_000;
    uint256 constant DEPOSIT = 1_000_000_000; // $1000 USDC

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        aUsdc = new MockAToken(address(usdc));
        aavePool = new MockAavePool(IERC20(address(usdc)), aUsdc);

        // fund the aave pool with USDC so it can pay withdrawals
        usdc.mint(address(aavePool), 100_000_000_000); // $100K liquidity

        vault = new AgentYield(
            IERC20(address(usdc)),
            IAavePool(address(aavePool)),
            IERC20(address(aUsdc)),
            treasury,
            owner,
            FEE_BPS
        );

        usdc.mint(alice, 10_000_000_000); // $10K
        usdc.mint(bob, 10_000_000_000);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(vault.name(), "Agent Yield USDC");
        assertEq(vault.symbol(), "ayUSDC");
        assertEq(vault.asset(), address(usdc));
        assertEq(address(vault.aavePool()), address(aavePool));
        assertEq(address(vault.aToken()), address(aUsdc));
        assertEq(vault.treasury(), treasury);
        assertEq(vault.owner(), owner);
        assertEq(vault.performanceFeeBps(), FEE_BPS);
        assertEq(vault.totalAssets(), 0);
    }

    function test_revert_constructorZeroAsset() public {
        vm.expectRevert(IAgentYield.ZeroAddress.selector);
        new AgentYield(IERC20(address(0)), IAavePool(address(aavePool)), IERC20(address(aUsdc)), treasury, owner, FEE_BPS);
    }

    function test_revert_constructorZeroPool() public {
        vm.expectRevert(IAgentYield.ZeroAddress.selector);
        new AgentYield(IERC20(address(usdc)), IAavePool(address(0)), IERC20(address(aUsdc)), treasury, owner, FEE_BPS);
    }

    function test_revert_constructorZeroAToken() public {
        vm.expectRevert(IAgentYield.ZeroAddress.selector);
        new AgentYield(IERC20(address(usdc)), IAavePool(address(aavePool)), IERC20(address(0)), treasury, owner, FEE_BPS);
    }

    function test_revert_constructorFeeTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentYield.FeeTooHigh.selector, 3001));
        new AgentYield(IERC20(address(usdc)), IAavePool(address(aavePool)), IERC20(address(aUsdc)), treasury, owner, 3001);
    }

    // ─── Deposit ────────────────────────────────────────────────────────

    function test_deposit() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT, alice);

        assertEq(shares, DEPOSIT); // 1:1 first deposit
        assertEq(vault.balanceOf(alice), DEPOSIT);
        assertEq(vault.totalAssets(), DEPOSIT); // aToken balance
        assertEq(usdc.balanceOf(address(vault)), 0); // USDC forwarded to Aave
    }

    function test_depositMultipleUsers() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vm.prank(bob);
        vault.deposit(DEPOSIT / 2, bob);

        assertEq(vault.totalAssets(), DEPOSIT + DEPOSIT / 2);
        assertEq(vault.totalSupply(), DEPOSIT + DEPOSIT / 2);
    }

    function test_revert_depositWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(DEPOSIT, alice);
    }

    function test_maxDepositZeroWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    // ─── Withdraw ───────────────────────────────────────────────────────

    function test_withdraw() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(DEPOSIT, alice, alice);

        assertEq(usdc.balanceOf(alice) - aliceBefore, DEPOSIT);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_withdrawWithYield() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // simulate 5% yield
        uint256 yield_ = DEPOSIT * 5 / 100; // 50M = $50
        aavePool.simulateYield(address(vault), yield_);

        assertEq(vault.totalAssets(), DEPOSIT + yield_);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 aliceShares = vault.balanceOf(alice);

        // alice redeems all shares — gets principal + yield
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        // she gets principal + yield (may lose 1 wei to rounding)
        uint256 received = usdc.balanceOf(alice) - aliceBefore;
        assertApproxEqAbs(received, DEPOSIT + yield_, 1);
    }

    function test_withdrawWorksWhenPaused() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(owner);
        vault.pause();

        // user can still exit
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
    }

    // ─── Harvest ────────────────────────────────────────────────────────

    function test_harvest() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // set baseline
        vault.harvest();
        assertEq(vault.lastHarvestedAssets(), DEPOSIT);

        // simulate yield
        uint256 yield_ = 50_000_000; // $50
        aavePool.simulateYield(address(vault), yield_);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vault.harvest();

        uint256 expectedFee = yield_ * FEE_BPS / BPS; // 10% of $50 = $5
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
        assertEq(vault.totalFeeCollected(), expectedFee);
    }

    function test_harvestSetsBaseline() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        // first harvest sets baseline
        vault.harvest();
        assertEq(vault.lastHarvestedAssets(), DEPOSIT);
    }

    function test_harvestMultipleTimes() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vault.harvest(); // baseline

        // first yield
        aavePool.simulateYield(address(vault), 10_000_000); // $10
        vault.harvest();

        uint256 firstFee = 10_000_000 * FEE_BPS / BPS; // $1

        // second yield
        aavePool.simulateYield(address(vault), 20_000_000); // $20
        vault.harvest();

        uint256 secondFee = 20_000_000 * FEE_BPS / BPS; // $2
        assertEq(vault.totalFeeCollected(), firstFee + secondFee);
    }

    function test_harvestPermissionless() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vault.harvest(); // baseline

        aavePool.simulateYield(address(vault), 50_000_000);

        // anyone can harvest
        vm.prank(bob);
        vault.harvest();

        assertGt(vault.totalFeeCollected(), 0);
    }

    function test_revert_harvestNoYield() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vault.harvest(); // baseline

        // no yield accrued
        vm.expectRevert(IAgentYield.NoYieldToHarvest.selector);
        vault.harvest();
    }

    function test_harvestZeroFee() public {
        // deploy with 0% fee
        AgentYield zeroFeeVault = new AgentYield(
            IERC20(address(usdc)),
            IAavePool(address(aavePool)),
            IERC20(address(aUsdc)),
            treasury,
            owner,
            0
        );

        vm.prank(alice);
        usdc.approve(address(zeroFeeVault), type(uint256).max);

        vm.prank(alice);
        zeroFeeVault.deposit(DEPOSIT, alice);

        zeroFeeVault.harvest(); // baseline

        aavePool.simulateYield(address(zeroFeeVault), 50_000_000);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        zeroFeeVault.harvest();

        assertEq(usdc.balanceOf(treasury), treasuryBefore); // no fee taken
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setPerformanceFeeBps() public {
        vm.prank(owner);
        vault.setPerformanceFeeBps(2000); // 20%

        assertEq(vault.performanceFeeBps(), 2000);
    }

    function test_revert_setFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentYield.FeeTooHigh.selector, 3001));
        vault.setPerformanceFeeBps(3001);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        vault.setTreasury(newTreasury);
        assertEq(vault.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentYield.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_revert_setFeeNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setPerformanceFeeBps(500);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_depositAndWithdraw(uint256 amount) public {
        amount = bound(amount, 1_000_000, 5_000_000_000); // $1 to $5K

        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice);

        assertEq(vault.totalAssets(), amount);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(usdc.balanceOf(alice) - aliceBefore, amount);
    }

    function testFuzz_harvestFeeCorrect(uint256 yield_) public {
        yield_ = bound(yield_, 1_000_000, 500_000_000); // $1 to $500

        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);

        vault.harvest(); // baseline

        aavePool.simulateYield(address(vault), yield_);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vault.harvest();

        uint256 expectedFee = yield_ * FEE_BPS / BPS;
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
    }

    function testFuzz_multiUserProportionalShares(uint256 aliceAmt, uint256 bobAmt) public {
        aliceAmt = bound(aliceAmt, 1_000_000, 5_000_000_000);
        bobAmt = bound(bobAmt, 1_000_000, 5_000_000_000);

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(aliceAmt, alice);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(bobAmt, bob);

        // shares proportional to deposits (1:1 ratio at start)
        assertEq(aliceShares, aliceAmt);
        assertEq(bobShares, bobAmt);
        assertEq(vault.totalAssets(), aliceAmt + bobAmt);
    }
}
