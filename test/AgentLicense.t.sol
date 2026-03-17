// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentLicense} from "../src/AgentLicense.sol";
import {IAgentLicense} from "../src/interfaces/IAgentLicense.sol";

contract AgentLicenseTest is Test {
    ERC20Mock usdc;
    AgentLicense license;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address ipOwner = makeAddr("ipOwner");
    address buyer1 = makeAddr("buyer1");
    address buyer2 = makeAddr("buyer2");

    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant BPS = 10_000;
    uint256 constant PRICE_PER_USE = 5_000_000; // $5
    uint256 constant SUB_PRICE = 10_000_000; // $10/month
    bytes32 constant CONTENT = keccak256("my-model-v1");

    function setUp() public {
        usdc = new ERC20Mock("USDC", "USDC", 6);
        license = new AgentLicense(IERC20(address(usdc)), treasury, owner, FEE_BPS);

        usdc.mint(buyer1, 10_000_000_000);
        usdc.mint(buyer2, 10_000_000_000);
        vm.prank(buyer1);
        usdc.approve(address(license), type(uint256).max);
        vm.prank(buyer2);
        usdc.approve(address(license), type(uint256).max);
    }

    function _registerDefault() internal returns (uint256) {
        vm.prank(ipOwner);
        return license.registerLicense("My Model", CONTENT, PRICE_PER_USE, SUB_PRICE);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(license.treasury(), treasury);
        assertEq(license.platformFeeBps(), FEE_BPS);
    }

    function test_revert_constructorZeroToken() public {
        vm.expectRevert(IAgentLicense.ZeroAddress.selector);
        new AgentLicense(IERC20(address(0)), treasury, owner, FEE_BPS);
    }

    // ─── Register ───────────────────────────────────────────────────────

    function test_registerLicense() public {
        uint256 id = _registerDefault();
        assertEq(id, 0);

        IAgentLicense.License memory l = license.getLicense(id);
        assertEq(l.ipOwner, ipOwner);
        assertEq(l.contentHash, CONTENT);
        assertEq(l.pricePerUse, PRICE_PER_USE);
        assertEq(l.subscriptionPrice, SUB_PRICE);
        assertTrue(l.active);
    }

    function test_revert_registerEmptyName() public {
        vm.prank(ipOwner);
        vm.expectRevert(IAgentLicense.EmptyName.selector);
        license.registerLicense("", CONTENT, PRICE_PER_USE, SUB_PRICE);
    }

    function test_revert_registerZeroHash() public {
        vm.prank(ipOwner);
        vm.expectRevert(IAgentLicense.InvalidContentHash.selector);
        license.registerLicense("X", bytes32(0), PRICE_PER_USE, SUB_PRICE);
    }

    function test_revert_registerZeroPrice() public {
        vm.prank(ipOwner);
        vm.expectRevert(IAgentLicense.InvalidPrice.selector);
        license.registerLicense("X", CONTENT, 0, SUB_PRICE);
    }

    // ─── Purchase Per-Use ───────────────────────────────────────────────

    function test_purchasePerUse() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 0); // PER_USE

        IAgentLicense.Licensee memory l = license.getLicensee(id, buyer1);
        assertEq(l.usesRemaining, 1);
        assertTrue(license.verifyLicense(id, buyer1));
    }

    function test_purchasePerUseMultiple() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 0);
        vm.prank(buyer1);
        license.purchaseLicense(id, 0);

        assertEq(license.getLicensee(id, buyer1).usesRemaining, 2);
    }

    // ─── Purchase Subscription ──────────────────────────────────────────

    function test_purchaseSubscription() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 1); // SUBSCRIPTION

        IAgentLicense.Licensee memory l = license.getLicensee(id, buyer1);
        assertEq(l.subscriptionEnd, uint48(block.timestamp + 30 days));
        assertTrue(license.verifyLicense(id, buyer1));
    }

    function test_subscriptionExpires() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 1);

        vm.warp(block.timestamp + 31 days);
        assertFalse(license.verifyLicense(id, buyer1));
    }

    function test_subscriptionExtends() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 1);
        uint48 firstEnd = license.getLicensee(id, buyer1).subscriptionEnd;

        vm.prank(buyer1);
        license.purchaseLicense(id, 1);

        assertEq(license.getLicensee(id, buyer1).subscriptionEnd, firstEnd + uint48(30 days));
    }

    // ─── Purchase Perpetual ─────────────────────────────────────────────

    function test_purchasePerpetual() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 2); // PERPETUAL

        assertTrue(license.getLicensee(id, buyer1).hasPerpetual);
        assertTrue(license.verifyLicense(id, buyer1));

        // still valid after years
        vm.warp(block.timestamp + 3650 days);
        assertTrue(license.verifyLicense(id, buyer1));
    }

    function test_revert_perpetualTwice() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 2);

        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLicense.AlreadyHasPerpetual.selector, id, buyer1));
        license.purchaseLicense(id, 2);
    }

    function test_perpetualCosts10x() public {
        uint256 id = _registerDefault();

        uint256 balBefore = usdc.balanceOf(buyer1);
        vm.prank(buyer1);
        license.purchaseLicense(id, 2);

        assertEq(balBefore - usdc.balanceOf(buyer1), PRICE_PER_USE * 10);
    }

    // ─── Usage ──────────────────────────────────────────────────────────

    function test_recordUsage() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 0); // 1 use

        vm.prank(buyer1);
        license.recordUsage(id);

        assertEq(license.getLicense(id).totalUses, 1);
        assertEq(license.getLicensee(id, buyer1).usesRemaining, 0);
    }

    function test_revert_usageNoLicense() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLicense.NoValidLicense.selector, id, buyer1));
        license.recordUsage(id);
    }

    function test_perpetualUnlimitedUsage() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 2);

        // use 100 times — perpetual never runs out
        vm.startPrank(buyer1);
        for (uint i; i < 100; i++) {
            license.recordUsage(id);
        }
        vm.stopPrank();

        assertEq(license.getLicense(id).totalUses, 100);
    }

    // ─── Royalties ──────────────────────────────────────────────────────

    function test_transferRoyalties() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 0);

        uint256 fee = PRICE_PER_USE * FEE_BPS / BPS;
        uint256 royalty = PRICE_PER_USE - fee;

        uint256 ownerBefore = usdc.balanceOf(ipOwner);
        license.transferRoyalties(id);

        assertEq(usdc.balanceOf(ipOwner) - ownerBefore, royalty);
        assertEq(license.getRoyalties(id), 0);
    }

    function test_royaltiesAccumulate() public {
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 0);
        vm.prank(buyer2);
        license.purchaseLicense(id, 0);

        uint256 fee = PRICE_PER_USE * FEE_BPS / BPS;
        uint256 expectedRoyalty = (PRICE_PER_USE - fee) * 2;
        assertEq(license.getRoyalties(id), expectedRoyalty);
    }

    function test_revert_noRoyalties() public {
        uint256 id = _registerDefault();
        vm.expectRevert(abi.encodeWithSelector(IAgentLicense.NoRoyaltiesToClaim.selector, id));
        license.transferRoyalties(id);
    }

    // ─── Deactivate ─────────────────────────────────────────────────────

    function test_deactivateLicense() public {
        uint256 id = _registerDefault();

        vm.prank(ipOwner);
        license.deactivateLicense(id);

        assertFalse(license.getLicense(id).active);
    }

    function test_revert_deactivateNotOwner() public {
        uint256 id = _registerDefault();
        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLicense.NotIPOwner.selector, id));
        license.deactivateLicense(id);
    }

    function test_revert_purchaseDeactivated() public {
        uint256 id = _registerDefault();
        vm.prank(ipOwner);
        license.deactivateLicense(id);

        vm.prank(buyer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLicense.LicenseNotActive.selector, id));
        license.purchaseLicense(id, 0);
    }

    // ─── Fee + Admin ────────────────────────────────────────────────────

    function test_collectFees() public {
        uint256 id = _registerDefault();
        vm.prank(buyer1);
        license.purchaseLicense(id, 0);

        uint256 before_ = usdc.balanceOf(treasury);
        license.collectFees();
        assertEq(usdc.balanceOf(treasury) - before_, PRICE_PER_USE * FEE_BPS / BPS);
    }

    function test_revert_collectNoFees() public {
        vm.expectRevert(IAgentLicense.NoFeesToCollect.selector);
        license.collectFees();
    }

    function test_setFee() public {
        vm.prank(owner);
        license.setPlatformFeeBps(200);
        assertEq(license.platformFeeBps(), 200);
    }

    function test_setTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(owner);
        license.setTreasury(newT);
        assertEq(license.treasury(), newT);
    }

    function test_revert_getLicenseNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentLicense.LicenseNotFound.selector, 999));
        license.getLicense(999);
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_royaltyCalculation(uint256 price) public {
        price = bound(price, 1_000_000, 1_000_000_000);

        vm.prank(ipOwner);
        uint256 id = license.registerLicense("Fuzz", CONTENT, price, 0);

        vm.prank(buyer1);
        license.purchaseLicense(id, 0);

        uint256 fee = price * FEE_BPS / BPS;
        uint256 expectedRoyalty = price - fee;
        assertEq(license.getRoyalties(id), expectedRoyalty);
    }

    function testFuzz_perpetualAlwaysValid(uint256 daysElapsed) public {
        daysElapsed = bound(daysElapsed, 0, 36500); // up to 100 years
        uint256 id = _registerDefault();

        vm.prank(buyer1);
        license.purchaseLicense(id, 2);

        vm.warp(block.timestamp + daysElapsed * 1 days);
        assertTrue(license.verifyLicense(id, buyer1));
    }
}
