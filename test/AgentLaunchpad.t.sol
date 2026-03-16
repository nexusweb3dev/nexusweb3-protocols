// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentLaunchpad} from "../src/AgentLaunchpad.sol";
import {IAgentLaunchpad} from "../src/interfaces/IAgentLaunchpad.sol";

contract AgentLaunchpadTest is Test {
    AgentLaunchpad launchpad;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address deployer1 = makeAddr("deployer1");
    address deployer2 = makeAddr("deployer2");
    address stranger = makeAddr("stranger");

    uint256 constant LAUNCH_FEE = 0.01 ether;

    function setUp() public {
        launchpad = new AgentLaunchpad(treasury, owner, LAUNCH_FEE);

        vm.deal(deployer1, 100 ether);
        vm.deal(deployer2, 100 ether);
    }

    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(launchpad.treasury(), treasury);
        assertEq(launchpad.owner(), owner);
        assertEq(launchpad.launchFee(), LAUNCH_FEE);
        assertEq(launchpad.protocolCount(), 0);
        assertEq(launchpad.accumulatedFees(), 0);
    }

    function test_revert_constructorZeroTreasury() public {
        vm.expectRevert(IAgentLaunchpad.ZeroAddress.selector);
        new AgentLaunchpad(address(0), owner, LAUNCH_FEE);
    }

    // ─── Launch Protocol ────────────────────────────────────────────────

    function test_launchProtocol() public {
        address contractAddr = makeAddr("myProtocol");

        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(contractAddr, "DeFi Protocol", 0);

        assertEq(launchpad.protocolCount(), 1);
        assertEq(launchpad.accumulatedFees(), LAUNCH_FEE);
        assertEq(launchpad.getDeployerProtocolCount(deployer1), 1);

        IAgentLaunchpad.Protocol memory p = launchpad.getProtocol(0);
        assertEq(p.deployer, deployer1);
        assertEq(p.contractAddress, contractAddr);
        assertEq(p.name, "DeFi Protocol");
        assertEq(p.category, 0);
        assertFalse(p.verified);
        assertFalse(p.revoked);
    }

    function test_launchMultipleProtocols() public {
        address contract1 = makeAddr("proto1");
        address contract2 = makeAddr("proto2");

        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(contract1, "Protocol One", 0);

        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(contract2, "Protocol Two", 1);

        assertEq(launchpad.protocolCount(), 2);
        assertEq(launchpad.getDeployerProtocolCount(deployer1), 2);
        assertEq(launchpad.accumulatedFees(), LAUNCH_FEE * 2);
    }

    function test_revert_launchProtocolZeroAddress() public {
        vm.prank(deployer1);
        vm.expectRevert(IAgentLaunchpad.ZeroAddress.selector);
        launchpad.launchProtocol{value: LAUNCH_FEE}(address(0), "Zero Addr", 0);
    }

    function test_revert_launchProtocolEmptyName() public {
        vm.prank(deployer1);
        vm.expectRevert(IAgentLaunchpad.EmptyName.selector);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "", 0);
    }

    function test_revert_launchProtocolInvalidCategory() public {
        vm.prank(deployer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.InvalidCategory.selector, uint8(5)));
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Bad Cat", 5);
    }

    function test_revert_launchProtocolInsufficientFee() public {
        vm.prank(deployer1);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentLaunchpad.InsufficientFee.selector, LAUNCH_FEE, LAUNCH_FEE - 1)
        );
        launchpad.launchProtocol{value: LAUNCH_FEE - 1}(makeAddr("contract"), "Cheap", 0);
    }

    function test_revert_launchProtocolWhenPaused() public {
        vm.prank(owner);
        launchpad.pause();

        vm.prank(deployer1);
        vm.expectRevert();
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Paused", 0);
    }

    // ─── Max Protocols Per Deployer ─────────────────────────────────────

    function test_revert_maxProtocolsPerDeployer() public {
        for (uint256 i = 0; i < 20; i++) {
            address contractAddr = makeAddr(string(abi.encodePacked("proto", i)));
            vm.prank(deployer1);
            launchpad.launchProtocol{value: LAUNCH_FEE}(contractAddr, "Protocol", 0);
        }

        assertEq(launchpad.getDeployerProtocolCount(deployer1), 20);

        vm.prank(deployer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.MaxProtocolsPerDeployer.selector, deployer1));
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("proto21"), "One Too Many", 0);
    }

    function test_maxProtocolsPerDeployer_differentDeployers() public {
        for (uint256 i = 0; i < 20; i++) {
            address contractAddr = makeAddr(string(abi.encodePacked("d1proto", i)));
            vm.prank(deployer1);
            launchpad.launchProtocol{value: LAUNCH_FEE}(contractAddr, "D1 Protocol", 0);
        }

        // deployer2 should still be able to launch
        vm.prank(deployer2);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("d2proto"), "D2 Protocol", 0);

        assertEq(launchpad.getDeployerProtocolCount(deployer2), 1);
    }

    // ─── Verify Protocol ────────────────────────────────────────────────

    function test_verifyProtocol() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Verify Me", 0);

        vm.prank(owner);
        launchpad.verifyProtocol(0);

        IAgentLaunchpad.Protocol memory p = launchpad.getProtocol(0);
        assertTrue(p.verified);
        assertFalse(p.revoked);
    }

    function test_revert_verifyProtocolNotOwner() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Not Owner", 0);

        vm.prank(deployer1);
        vm.expectRevert();
        launchpad.verifyProtocol(0);
    }

    function test_revert_verifyProtocolNotFound() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.ProtocolNotFound.selector, 0));
        launchpad.verifyProtocol(0);
    }

    function test_revert_verifyAlreadyVerified() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Already V", 0);

        vm.prank(owner);
        launchpad.verifyProtocol(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.AlreadyVerified.selector, 0));
        launchpad.verifyProtocol(0);
    }

    function test_revert_verifyRevokedProtocol() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Revoked", 0);

        vm.prank(owner);
        launchpad.revokeProtocol(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.AlreadyRevoked.selector, 0));
        launchpad.verifyProtocol(0);
    }

    // ─── Revoke Protocol ────────────────────────────────────────────────

    function test_revokeProtocol() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Revoke Me", 0);

        vm.prank(owner);
        launchpad.revokeProtocol(0);

        IAgentLaunchpad.Protocol memory p = launchpad.getProtocol(0);
        assertFalse(p.verified);
        assertTrue(p.revoked);
    }

    function test_revokeVerifiedProtocol() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Verify Then Revoke", 0);

        vm.prank(owner);
        launchpad.verifyProtocol(0);

        vm.prank(owner);
        launchpad.revokeProtocol(0);

        IAgentLaunchpad.Protocol memory p = launchpad.getProtocol(0);
        assertFalse(p.verified); // verification removed
        assertTrue(p.revoked);
    }

    function test_revert_revokeProtocolNotOwner() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Not Owner", 0);

        vm.prank(deployer1);
        vm.expectRevert();
        launchpad.revokeProtocol(0);
    }

    function test_revert_revokeProtocolNotFound() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.ProtocolNotFound.selector, 999));
        launchpad.revokeProtocol(999);
    }

    function test_revert_revokeAlreadyRevoked() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Double Revoke", 0);

        vm.prank(owner);
        launchpad.revokeProtocol(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.AlreadyRevoked.selector, 0));
        launchpad.revokeProtocol(0);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function test_collectFees() public {
        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("c1"), "P1", 0);

        vm.prank(deployer2);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("c2"), "P2", 1);

        uint256 totalFees = LAUNCH_FEE * 2;
        uint256 treasuryBefore = treasury.balance;

        launchpad.collectFees();

        assertEq(treasury.balance - treasuryBefore, totalFees);
        assertEq(launchpad.accumulatedFees(), 0);
    }

    function test_revert_collectFeesNoFees() public {
        vm.expectRevert(IAgentLaunchpad.NoFeesToCollect.selector);
        launchpad.collectFees();
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function test_setLaunchFee() public {
        uint256 newFee = 0.05 ether;

        vm.prank(owner);
        launchpad.setLaunchFee(newFee);

        assertEq(launchpad.launchFee(), newFee);
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        launchpad.setTreasury(newTreasury);

        assertEq(launchpad.treasury(), newTreasury);
    }

    function test_revert_setTreasuryZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentLaunchpad.ZeroAddress.selector);
        launchpad.setTreasury(address(0));
    }

    function test_pauseUnpause() public {
        vm.prank(owner);
        launchpad.pause();

        vm.prank(deployer1);
        vm.expectRevert();
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Paused", 0);

        vm.prank(owner);
        launchpad.unpause();

        vm.prank(deployer1);
        launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("contract"), "Unpaused", 0);
        assertEq(launchpad.protocolCount(), 1);
    }

    // ─── View ───────────────────────────────────────────────────────────

    function test_revert_getProtocolNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.ProtocolNotFound.selector, 0));
        launchpad.getProtocol(0);
    }

    // ─── Fuzz Tests ─────────────────────────────────────────────────────

    function testFuzz_launchFees(uint256 fee) public {
        fee = bound(fee, 0.001 ether, 1 ether);

        vm.prank(owner);
        launchpad.setLaunchFee(fee);

        vm.prank(deployer1);
        launchpad.launchProtocol{value: fee}(makeAddr("fuzzContract"), "Fuzz Proto", 0);

        assertEq(launchpad.accumulatedFees(), fee);
        assertEq(address(launchpad).balance, fee);
    }

    function testFuzz_launchFeeInsufficientRevert(uint256 fee, uint256 paid) public {
        fee = bound(fee, 0.01 ether, 1 ether);
        paid = bound(paid, 0, fee - 1);

        vm.prank(owner);
        launchpad.setLaunchFee(fee);

        vm.prank(deployer1);
        vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.InsufficientFee.selector, fee, paid));
        launchpad.launchProtocol{value: paid}(makeAddr("fuzzContract"), "Underpaid", 0);
    }

    function testFuzz_categoryValidation(uint8 category) public {
        if (category <= 4) {
            vm.prank(deployer1);
            launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("catContract"), "Cat Proto", category);
            assertEq(launchpad.getProtocol(0).category, category);
        } else {
            vm.prank(deployer1);
            vm.expectRevert(abi.encodeWithSelector(IAgentLaunchpad.InvalidCategory.selector, category));
            launchpad.launchProtocol{value: LAUNCH_FEE}(makeAddr("catContract"), "Bad Cat", category);
        }
    }

    function testFuzz_collectFeesMultipleLaunches(uint8 launchCount) public {
        launchCount = uint8(bound(launchCount, 1, 20));
        uint256 expectedTotal;

        for (uint8 i = 0; i < launchCount; i++) {
            address contractAddr = makeAddr(string(abi.encodePacked("fuzz", i)));
            vm.prank(deployer1);
            launchpad.launchProtocol{value: LAUNCH_FEE}(contractAddr, "Fuzz", 0);
            expectedTotal += LAUNCH_FEE;
        }

        assertEq(launchpad.accumulatedFees(), expectedTotal);

        uint256 treasuryBefore = treasury.balance;
        launchpad.collectFees();
        assertEq(treasury.balance - treasuryBefore, expectedTotal);
    }
}
