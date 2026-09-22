// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {MockReferral} from "../mocks/MockReferral.sol";

import {AgentAccess} from "../../../src/v2/AgentAccess.sol";
import {IAgentAccess} from "../../../src/v2/interfaces/IAgentAccess.sol";
import {AgentKillSwitchV2} from "../../../src/v2/AgentKillSwitchV2.sol";
import {IAgentKillSwitchV2} from "../../../src/v2/interfaces/IAgentKillSwitchV2.sol";
import {FeeRouter} from "../../../src/v2/FeeRouter.sol";
import {IFeeRouter} from "../../../src/v2/interfaces/IFeeRouter.sol";

/// @notice Referral sink that first tries to take the router's ENTIRE balance and, when that is
///         refused, falls back to pulling exactly the allowance it was granted. Used by FR-1.
contract DrainReferral {
    using SafeERC20 for IERC20;

    error NotSelf();

    IERC20 public immutable token;
    address public immutable thief;
    bool public fullBalanceGrabFailed;

    constructor(IERC20 token_, address thief_) {
        token = token_;
        thief = thief_;
    }

    function recordFee(address, uint256, address) external payable {
        uint256 all = token.balanceOf(msg.sender);
        try this.pull(msg.sender, all) {}
        catch {
            fullBalanceGrabFailed = true;
        }
        uint256 allowed = token.allowance(msg.sender, address(this));
        if (allowed > 0) token.safeTransferFrom(msg.sender, thief, allowed);
    }

    /// @dev External only so the greedy attempt can run under try/catch without reverting `route`.
    function pull(address from, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        token.safeTransferFrom(from, thief, amount);
    }
}

/// @notice USDC-like token with a transfer blocklist, to model a blacklisted fee recipient. Used by FR-3.
contract BlocklistToken is ERC20 {
    mapping(address => bool) public blocked;

    error Blocked(address account);

    constructor() ERC20("Blocklist USD", "bUSD") {}

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}

/// @title AuditGuardsTest
/// @notice Pre-deployment audit proofs of concept for AgentAccess, OperatorGated, AgentKillSwitchV2
///         and FeeRouter, migrated to the fixed contracts. Every test asserts the CURRENT on-chain
///         behaviour, so the suite is green: tests tagged `FIXED` keep the original scenario and now
///         assert the guarantee the fix provides, tests tagged `FINDING` encode behaviour the audit
///         reports as wrong and that is still accepted, and `SAFE` locks in correct behaviour.
contract AuditGuardsTest is Test {
    AgentAccess access;
    AgentKillSwitchV2 ks;
    ERC20Mock usdc;
    MockReferral referral;
    FeeRouter router;

    address owner = makeAddr("owner");
    address principal = makeAddr("principal");
    address operator = makeAddr("operator");
    address guardian = makeAddr("guardian");
    address subOperator = makeAddr("subOperator");
    address protocolA = makeAddr("protocolA");
    address protocolB = makeAddr("protocolB");
    address treasury = makeAddr("treasury");
    address staking = makeAddr("staking");
    address agent = makeAddr("agent");
    address referrer = makeAddr("referrer");
    address thief = makeAddr("thief");

    uint128 constant LIMIT = 1_000_000_000; // $1000 USDC
    uint48 constant SESSION = 1 days;
    uint16 constant STAKING_BPS = 7000;
    uint16 constant TREASURY_BPS = 3000;
    uint256 constant REFERRAL_BPS = 1000;
    uint256 constant BPS = 10_000;
    uint256 constant AMOUNT = 1_000_000_000;

    function setUp() public {
        vm.warp(1_700_000_000);

        access = new AgentAccess();
        ks = new AgentKillSwitchV2(owner);
        vm.startPrank(owner);
        ks.authorizeProtocol(protocolA);
        vm.stopPrank();

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        referral = new MockReferral(IERC20(address(usdc)), REFERRAL_BPS);
        router = new FeeRouter(
            IERC20(address(usdc)), owner, treasury, staking, address(referral), STAKING_BPS, TREASURY_BPS
        );
        vm.prank(owner);
        router.authorizeProtocol(protocolA);
    }

    function _register() internal {
        vm.prank(principal);
        ks.register(LIMIT, 0, SESSION);
    }

    function _consume(address who, uint256 amount) internal {
        vm.prank(protocolA);
        ks.consume(who, amount);
    }

    function _fund(uint256 amount) internal {
        usdc.mint(address(router), amount);
    }

    function _route(uint256 amount) internal {
        vm.prank(protocolA);
        router.route(agent, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    // AgentAccess / OperatorGated
    // ══════════════════════════════════════════════════════════════════════

    /// SAFE: an operator authorizing a third party only creates an operator for ITSELF, because
    /// `authorizeOperator` keys on `msg.sender`. Sub-delegation to the principal is impossible.
    function test_access_operatorCannotSubDelegateForPrincipal() public {
        vm.prank(principal);
        access.authorizeOperator(operator, type(uint48).max);

        vm.prank(operator);
        access.authorizeOperator(subOperator, type(uint48).max);

        assertTrue(access.isOperatorFor(principal, operator), "operator must be valid for principal");
        assertFalse(access.isOperatorFor(principal, subOperator), "sub-operator must NOT reach principal");
        assertTrue(access.isOperatorFor(operator, subOperator), "sub-operator only binds to the operator");
        assertEq(access.operatorExpiry(principal, subOperator), 0);
    }

    /// SAFE: expiry is exclusive on both sides. `authorizeOperator` needs `expiry > now`, and
    /// `isOperatorFor` needs `expiry > now`, so authorization dies exactly AT `expiry`, never after.
    function test_access_expiryIsExclusiveOnBothSides() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        vm.prank(principal);
        access.authorizeOperator(operator, expiry);

        vm.warp(expiry - 1);
        assertTrue(access.isOperatorFor(principal, operator), "valid one second before expiry");

        vm.warp(expiry);
        assertFalse(access.isOperatorFor(principal, operator), "invalid exactly at expiry");

        // The mirrored check on the write side: `expiry == block.timestamp` is rejected.
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.ExpiryInPast.selector, uint48(block.timestamp)));
        access.authorizeOperator(operator, uint48(block.timestamp));
    }

    /// FINDING ACC-1 (Informational): an authorization for `block.timestamp + 1` is live only for the
    /// remainder of the current block and is dead in the very next second. Grants shorter than one
    /// block are silently useless rather than rejected.
    function test_access_oneSecondGrantIsLiveOnlyInTheCurrentBlock() public {
        uint48 expiry = uint48(block.timestamp + 1);
        vm.prank(principal);
        access.authorizeOperator(operator, expiry);

        assertTrue(access.isOperatorFor(principal, operator), "live in the authorizing block");
        vm.warp(block.timestamp + 1);
        assertFalse(access.isOperatorFor(principal, operator), "dead one second later");
    }

    /// SAFE: `type(uint48).max` is a practical never-expires sentinel and needs no special casing.
    function test_access_maxUint48IsEffectivelyPermanent() public {
        vm.prank(principal);
        access.authorizeOperator(operator, type(uint48).max);

        vm.warp(type(uint48).max - 1);
        assertTrue(access.isOperatorFor(principal, operator));
        assertEq(access.operatorExpiry(principal, operator), type(uint48).max);
    }

    /// SAFE: re-authorization overwrites in both directions; shortening takes effect immediately and
    /// cannot be used to back-date an authorization into the past.
    function test_access_reauthorizationShortensAndLengthens() public {
        vm.startPrank(principal);
        access.authorizeOperator(operator, type(uint48).max);

        uint48 shortened = uint48(block.timestamp + 10 minutes);
        access.authorizeOperator(operator, shortened);
        assertEq(access.operatorExpiry(principal, operator), shortened);

        uint48 lengthened = uint48(block.timestamp + 30 days);
        access.authorizeOperator(operator, lengthened);
        assertEq(access.operatorExpiry(principal, operator), lengthened);

        // Shortening to the past is not a revocation path: it reverts.
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.ExpiryInPast.selector, uint48(block.timestamp - 1)));
        access.authorizeOperator(operator, uint48(block.timestamp - 1));
        vm.stopPrank();
    }

    /// SAFE: zero address, self-authorization and revoking a never-authorized operator all revert.
    /// Self is implicitly an operator via `isOperatorFor`, so an explicit entry is redundant.
    function test_access_inputGuards() public {
        vm.startPrank(principal);

        vm.expectRevert(IAgentAccess.ZeroAddress.selector);
        access.authorizeOperator(address(0), type(uint48).max);

        vm.expectRevert(IAgentAccess.SelfOperator.selector);
        access.authorizeOperator(principal, type(uint48).max);

        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.NotOperator.selector, principal, operator));
        access.revokeOperator(operator);

        vm.stopPrank();

        assertTrue(access.isOperatorFor(principal, principal), "principal is always its own operator");
        assertFalse(access.isOperatorFor(address(0), address(0)) == false, "zero is trivially self");
    }

    /// FINDING ACC-2 (Informational): an EXPIRED operator still has a non-zero storage entry, so
    /// `revokeOperator` succeeds and `operatorExpiry` returns a stale, already-dead timestamp.
    /// Off-chain monitors that treat non-zero expiry as "authorized" read this wrong.
    function test_access_expiredOperatorKeepsStaleStorageEntry() public {
        uint48 expiry = uint48(block.timestamp + 1 hours);
        vm.prank(principal);
        access.authorizeOperator(operator, expiry);

        vm.warp(expiry + 1);
        assertFalse(access.isOperatorFor(principal, operator), "expired");
        assertEq(access.operatorExpiry(principal, operator), expiry, "storage still non-zero after expiry");

        vm.prank(principal);
        access.revokeOperator(operator); // succeeds on an already-dead entry
        assertEq(access.operatorExpiry(principal, operator), 0);
    }

    /// FIXED: ACC-3
    /// @dev The fix guarantees a key holder that knows its key is compromised can drop the authority
    /// itself, without waiting for the principal, via `renounceOperator`.
    function test_access_operatorCanRenounceItsOwnAuthorization() public {
        vm.prank(principal);
        access.authorizeOperator(operator, type(uint48).max);

        vm.prank(operator);
        vm.expectEmit(true, true, false, false, address(access));
        emit IAgentAccess.OperatorRenounced(principal, operator);
        access.renounceOperator(principal);

        assertFalse(access.isOperatorFor(principal, operator), "operator dropped its own authority");
        assertEq(access.operatorExpiry(principal, operator), 0, "storage entry cleared");

        // Renouncing an authorization that was never granted still reverts.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.NotOperator.selector, principal, operator));
        access.renounceOperator(principal);

        // Renouncing is scoped: it touches only the caller's own grant from that principal.
        vm.prank(principal);
        access.authorizeOperator(operator, type(uint48).max);
        vm.prank(subOperator);
        vm.expectRevert(abi.encodeWithSelector(IAgentAccess.NotOperator.selector, principal, subOperator));
        access.renounceOperator(principal);
        assertTrue(access.isOperatorFor(principal, operator));
    }

    // ══════════════════════════════════════════════════════════════════════
    // AgentKillSwitchV2
    // ══════════════════════════════════════════════════════════════════════

    /// FIXED: KS-1
    /// @dev The fix guarantees the headroom subtraction is clamped, so lowering `spendingLimit` below
    /// the session's `spent` reports zero headroom instead of an arithmetic panic.
    function test_ks_remainingSpendReturnsZeroWhenLimitLoweredBelowSpent() public {
        _register();
        _consume(principal, 500_000_000);
        assertEq(ks.remainingSpend(principal), LIMIT - 500_000_000);

        vm.prank(principal);
        ks.setLimits(100_000_000, 0, SESSION); // new limit < already spent

        assertEq(ks.remainingSpend(principal), 0, "clamped to zero, never reverts");
    }

    /// FIXED: KS-1
    /// @dev The fix guarantees `consume` reverts with the documented `SpendingLimitExceeded` and a
    /// clamped `remaining`, so integrators matching on the custom error still see it.
    function test_ks_consumeRevertsWithSpendingLimitExceededAfterLimitLowered() public {
        _register();
        _consume(principal, 500_000_000);

        vm.prank(principal);
        ks.setLimits(100_000_000, 0, SESSION);

        vm.prank(protocolA);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, principal, 1, 0));
        ks.consume(principal, 1);
    }

    /// SAFE (contrast case): when `spent <= spendingLimit` the same path reverts with the intended
    /// custom error and correct remaining amount.
    function test_ks_consumeRevertsCleanlyWhenLimitNotLowered() public {
        _register();
        _consume(principal, LIMIT);

        vm.prank(protocolA);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, principal, 1, 0));
        ks.consume(principal, 1);
    }

    /// FIXED: KS-2
    /// @dev The fix guarantees `resetSession` is principal-only, so the guardian brake can never be
    /// run in reverse to refill the spending budget inside a session.
    function test_ks_guardianCannotResetSessionToRefillSpendingBudget() public {
        _register();
        vm.prank(principal);
        ks.setGuardian(guardian);

        _consume(principal, LIMIT);
        vm.prank(protocolA);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, principal, 1, 0));
        ks.consume(principal, 1);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipal.selector, principal, guardian));
        ks.resetSession(principal);

        assertEq(ks.remainingSpend(principal), 0, "per-session cap is a cap");
        assertEq(ks.getConfig(principal).spent, LIMIT, "counter still shows the whole session");
        assertLt(block.timestamp, uint256(ks.getConfig(principal).sessionStart) + SESSION, "session never expired");

        // The guardian keeps exactly the restrict-only powers it is documented to have.
        vm.prank(guardian);
        ks.pause(principal);
        assertFalse(ks.isActive(principal));
    }

    /// FIXED: KS-2
    /// @dev The fix guarantees the header invariant "operator hot keys can never widen limits": an
    /// operator named as guardian is blocked from both `setLimits` and `resetSession`.
    function test_ks_operatorAsGuardianCannotWidenLimits() public {
        _register();
        vm.startPrank(principal);
        access.authorizeOperator(operator, type(uint48).max);
        ks.setGuardian(operator); // plausible ops setup: let the hot key hit the brake
        vm.stopPrank();

        _consume(principal, LIMIT);
        assertEq(ks.remainingSpend(principal), 0);

        // setLimits is blocked for the operator ...
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotRegistered.selector, operator));
        ks.setLimits(type(uint128).max, 0, SESSION);

        // ... and so is resetSession, which used to achieve the same outcome.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.NotPrincipal.selector, principal, operator));
        ks.resetSession(principal);

        assertEq(ks.remainingSpend(principal), 0, "hot key could not restore a budget");
    }

    /// SAFE: the principal itself can still reset its own session, which is the documented use.
    function test_ks_principalCanResetItsOwnSession() public {
        _register();
        _consume(principal, LIMIT);
        assertEq(ks.remainingSpend(principal), 0);

        vm.prank(principal);
        ks.resetSession(principal);
        assertEq(ks.remainingSpend(principal), LIMIT, "principal restored its own budget");
    }

    /// FINDING KS-3 (Informational): a guardian's `kill` is undone by the principal in the very next
    /// transaction, with no timelock or guardian consent. The guardian is advisory, not a brake, if
    /// the principal key is the thing that was compromised.
    function test_ks_guardianKillIsImmediatelyReversibleByPrincipal() public {
        _register();
        vm.prank(principal);
        ks.setGuardian(guardian);

        vm.prank(guardian);
        ks.kill(principal);
        assertFalse(ks.isActive(principal));

        vm.prank(principal);
        ks.resume();
        assertTrue(ks.isActive(principal), "principal un-killed itself with no delay");

        // The guardian cannot re-assert control durably either: the loop can repeat forever.
        vm.prank(guardian);
        ks.kill(principal);
        vm.prank(principal);
        ks.resume();
        assertTrue(ks.isActive(principal));
    }

    /// FINDING KS-4 (Low): `consume` moves no funds, but ANY authorized protocol can burn ANY agent's
    /// session budget without that agent transacting, denying it escrow jobs until the session rolls
    /// (up to 365 days). AgentKillSwitchV2.sol:133.
    function test_ks_anyAuthorizedProtocolCanBurnAnotherAgentsBudget() public {
        _register();
        vm.prank(owner);
        ks.authorizeProtocol(protocolB);

        uint256 before = usdc.balanceOf(principal);
        vm.prank(protocolB);
        ks.consume(principal, LIMIT); // principal never interacted with protocolB

        assertEq(ks.remainingSpend(principal), 0, "budget griefed to zero");
        assertEq(usdc.balanceOf(principal), before, "no funds moved: consume is accounting only");

        vm.prank(protocolA);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.SpendingLimitExceeded.selector, principal, 1, 0));
        ks.consume(principal, 1);
    }

    /// SAFE: registration is one-way. There is no deregister, and `registered` is never cleared by
    /// kill/resume/pause/reset, so an agent cannot escape its own limits by unregistering.
    function test_ks_registrationIsOneWayNoDeregisterPath() public {
        _register();
        vm.startPrank(principal);
        ks.kill(principal);
        ks.resume();
        vm.stopPrank();
        vm.prank(protocolA);
        ks.consume(principal, 1);

        assertTrue(ks.getConfig(principal).registered, "registered survives every state transition");

        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AlreadyRegistered.selector, principal));
        ks.register(type(uint128).max, 0, SESSION);
    }

    /// SAFE: unregistered agents bypass the switch by design — `isActive` is true and `remainingSpend`
    /// is unbounded — which is what lets escrow gate providers without forcing them to register.
    function test_ks_unregisteredAgentIsActiveAndUnbounded() public {
        address stranger = makeAddr("stranger");
        assertTrue(ks.isActive(stranger));
        assertEq(ks.remainingSpend(stranger), type(uint256).max);

        vm.prank(protocolA);
        ks.consume(stranger, type(uint256).max); // silent no-op, no revert
        assertEq(ks.getConfig(stranger).spent, 0);
    }

    /// SAFE: session expiry math widens both operands to uint256 before adding, so it cannot overflow
    /// even at the top of the uint48 timestamp range.
    function test_ks_sessionMathSafeAtUint48Extremes() public {
        vm.warp(uint256(type(uint48).max) - 400 days);
        vm.prank(principal);
        ks.register(LIMIT, 0, uint48(365 days));

        vm.warp(uint256(type(uint48).max) - 1);
        vm.prank(protocolA);
        ks.consume(principal, 1); // rolls the expired session, no overflow

        assertEq(ks.getConfig(principal).spent, 1);
        assertEq(ks.getConfig(principal).sessionStart, type(uint48).max - 1);
    }

    /// SAFE: a killed agent stays killed across a session roll — the roll happens first, then the
    /// kill check reverts, and the whole transaction unwinds so no SessionReset is persisted.
    function test_ks_killSurvivesAndRollIsNotPersistedOnRevert() public {
        _register();
        _consume(principal, 100);
        vm.prank(principal);
        ks.kill(principal);

        uint48 startBefore = ks.getConfig(principal).sessionStart;
        vm.warp(block.timestamp + SESSION + 1);

        vm.prank(protocolA);
        vm.expectRevert(abi.encodeWithSelector(IAgentKillSwitchV2.AgentIsKilled.selector, principal));
        ks.consume(principal, 1);

        assertEq(ks.getConfig(principal).sessionStart, startBefore, "reverted roll left no trace");
        assertEq(ks.getConfig(principal).spent, 100, "counters unchanged");
    }

    // ══════════════════════════════════════════════════════════════════════
    // FeeRouter
    // ══════════════════════════════════════════════════════════════════════

    /// FIXED: FR-1
    /// @dev The fix guarantees the referral sink is approved for exactly the fee being routed and the
    /// allowance is zeroed straight after, so a malicious sink can never reach the router's surplus.
    function test_fr_maliciousReferralIsBoundedToTheRoutedFee() public {
        DrainReferral drainer = new DrainReferral(IERC20(address(usdc)), thief);
        vm.prank(owner);
        router.setReferral(address(drainer));

        _fund(AMOUNT * 5); // one routed fee plus four fees' worth of surplus sitting in the router

        vm.expectEmit(true, true, false, true, address(router));
        emit IFeeRouter.FeeRouted(protocolA, agent, AMOUNT, AMOUNT, 0, 0);
        _route(AMOUNT);

        assertTrue(drainer.fullBalanceGrabFailed(), "grabbing the whole router balance was refused");
        assertEq(usdc.balanceOf(thief), AMOUNT, "the sink got exactly the fee it was offered");
        assertEq(usdc.balanceOf(address(router)), AMOUNT * 4, "the surplus is untouched");
        assertEq(usdc.allowance(address(router), address(drainer)), 0, "allowance zeroed after the call");
    }

    /// FIXED: FR-2
    /// @dev The fix guarantees a swallowed referral revert is observable on-chain: `ReferralCallFailed`
    /// separates "the referral contract rejected us" from "this agent has no referrer".
    function test_fr_revertingReferralEmitsReferralCallFailed() public {
        uint256 stakingShare = (AMOUNT * STAKING_BPS) / BPS;
        uint256 treasuryShare = AMOUNT - stakingShare;

        // Case A: the agent HAS a referrer, but the referral contract rejects the router.
        referral.setReferrer(agent, referrer);
        referral.setShouldRevert(true);
        _fund(AMOUNT);
        vm.expectEmit(true, false, false, true, address(router));
        emit IFeeRouter.ReferralCallFailed(agent, AMOUNT);
        vm.expectEmit(true, true, false, true, address(router));
        emit IFeeRouter.FeeRouted(protocolA, agent, AMOUNT, 0, stakingShare, treasuryShare);
        _route(AMOUNT);

        uint256 stakingAfterA = usdc.balanceOf(staking);
        assertEq(usdc.balanceOf(address(referral)), 0, "referrer still earns nothing ...");

        // Case B: the agent genuinely has no referrer. Same balances, but NO failure event.
        referral.setShouldRevert(false);
        referral.setReferrer(agent, address(0));
        _fund(AMOUNT);
        vm.recordLogs();
        _route(AMOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != IFeeRouter.ReferralCallFailed.selector,
                "... but the healthy case is now distinguishable on-chain"
            );
        }

        assertEq(usdc.balanceOf(staking) - stakingAfterA, stakingShare, "balances are identical in both cases");
    }

    /// FINDING FR-3 (Low): a fee recipient that cannot receive the token (USDC blocklist, or a
    /// contract that reverts) makes every `route` revert. Escrow absorbs this — `_routeFee` catches
    /// and parks the fee as owner-claimable (EscrowBase.sol:230-245, already covered by
    /// Integration.t.sol:322) — but any other caller of `route` has no such fallback.
    function test_fr_blockedStakingRecipientRevertsRouteUntilOwnerFixesRecipients() public {
        BlocklistToken token = new BlocklistToken();
        FeeRouter blockRouter =
            new FeeRouter(IERC20(address(token)), owner, treasury, staking, address(0), STAKING_BPS, TREASURY_BPS);
        vm.prank(owner);
        blockRouter.authorizeProtocol(protocolA);

        token.mint(address(blockRouter), AMOUNT);
        token.setBlocked(staking, true);

        vm.prank(protocolA);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, staking));
        blockRouter.route(agent, AMOUNT);

        // Recovery is an owner action; nothing is lost, the fee just stays put until then.
        address freshStaking = makeAddr("freshStaking");
        vm.prank(owner);
        blockRouter.setRecipients(treasury, freshStaking);

        vm.prank(protocolA);
        blockRouter.route(agent, AMOUNT);
        assertEq(token.balanceOf(freshStaking), (AMOUNT * STAKING_BPS) / BPS);
    }

    /// SAFE: the `uninitialized-local` Slither hit on `referralPaid` is benign. With referrals
    /// disabled the variable keeps its zero default and the full amount reaches the recipients.
    function test_fr_uninitializedReferralPaidIsBenignWhenReferralDisabled() public {
        vm.prank(owner);
        router.setReferral(address(0));
        assertEq(usdc.allowance(address(router), address(referral)), 0, "old allowance revoked");

        _fund(AMOUNT);
        _route(AMOUNT);

        assertEq(usdc.balanceOf(staking) + usdc.balanceOf(treasury), AMOUNT);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    /// SAFE: conservation holds for every referral rate and every surplus — the routed `amount` is
    /// split exactly three ways and the router's surplus is never touched by an honest referral.
    function testFuzz_fr_conservationAcrossReferralRates(uint96 amount, uint96 surplus, uint16 refBps) public {
        amount = uint96(bound(amount, 1, type(uint96).max / 2));
        surplus = uint96(bound(surplus, 0, type(uint96).max / 2));
        refBps = uint16(bound(refBps, 0, 10_000));

        MockReferral sink = new MockReferral(IERC20(address(usdc)), refBps);
        sink.setReferrer(agent, referrer);
        vm.prank(owner);
        router.setReferral(address(sink));

        _fund(uint256(amount) + uint256(surplus));
        _route(amount);

        uint256 paidReferral = usdc.balanceOf(address(sink));
        assertEq(paidReferral + usdc.balanceOf(staking) + usdc.balanceOf(treasury), amount, "exact three-way split");
        assertEq(usdc.balanceOf(address(router)), surplus, "surplus untouched by an honest referral");
    }

    /// SAFE: `route` is nonReentrant, so a referral sink calling back in mid-route cannot double-spend
    /// the same balance. Proven here by the drain case reverting when it re-enters.
    function test_fr_reentrantReferralIsBlocked() public {
        ReentrantReferral attacker = new ReentrantReferral(router);
        vm.prank(owner);
        router.setReferral(address(attacker));

        _fund(AMOUNT * 2);
        _route(AMOUNT); // inner re-entrant route() reverts and is swallowed by the try/catch

        assertTrue(attacker.reenterFailed(), "nested route() was rejected by the reentrancy guard");
        assertEq(usdc.balanceOf(staking) + usdc.balanceOf(treasury), AMOUNT, "exactly one fee routed");
    }
}

/// @notice Referral sink that tries to re-enter `route` during `recordFee`. Used by the SAFE
///         reentrancy proof above.
contract ReentrantReferral {
    FeeRouter public immutable router;
    bool public reenterFailed;

    constructor(FeeRouter router_) {
        router = router_;
    }

    function recordFee(address agent, uint256 amount, address) external payable {
        try router.route(agent, amount) {}
        catch {
            reenterFailed = true;
        }
    }
}
