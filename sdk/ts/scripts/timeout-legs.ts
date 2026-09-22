/**
 * Timeout legs of the e2e: `settleExpired` and cancelling an offer nobody accepted.
 *
 * Both exercise the post-audit rule that time, not silence, decides an escrow job: work that was
 * submitted vests to the provider, work that was never delivered comes back to the client, and an
 * offer no provider accepted refunds in full.
 */
import { keccak256, stringToHex, type Address, type TestClient } from 'viem';
import { parseUsdc } from '../src/amount.js';
import type { NexusClient } from '../src/client.js';
import type { NexusPublicClient } from '../src/types.js';

/** Reported to the caller's PASS/FAIL tracker; keeps this module free of process concerns. */
export type Check = (name: string, ok: boolean, detail: string) => void;

export interface TimeoutLegParams {
  publicClient: NexusPublicClient;
  /** Signs as the client principal's operator. */
  clientOperator: NexusClient;
  /** Signs as the provider principal's operator. */
  providerOperator: NexusClient;
  /** Neither party to the job: proves `settleExpired` is permissionless. */
  bystander: NexusClient;
  clientAddress: Address;
  providerAddress: Address;
  testClient: TestClient;
  check: Check;
  /** Suffix that keeps deliverable hashes unique across runs against a persistent chain. */
  suffix: string;
}

const SUBMITTED_USDC = '60';
const PENDING_USDC = '40';
const CANCEL_USDC = '90';
const SUBMITTED_AMOUNT = parseUsdc(SUBMITTED_USDC);
const PENDING_AMOUNT = parseUsdc(PENDING_USDC);
const CANCEL_AMOUNT = parseUsdc(CANCEL_USDC);
/** Two days: short enough that the 8-day jump clears max(deadline, submittedAt + review window). */
const SETTLE_DEADLINE_SECONDS = 2 * 24 * 60 * 60;
const EXPIRY_SKIP_SECONDS = 8 * 24 * 60 * 60;

/** Client goes silent after one submission; an unrelated third party settles the job. */
export async function runSettleLeg(params: TimeoutLegParams): Promise<void> {
  const { publicClient, clientOperator, providerOperator, bystander, check } = params;
  const { clientAddress, providerAddress, testClient, suffix } = params;

  const block = await publicClient.getBlock();
  const created = await clientOperator.escrow.createJob({
    client: clientAddress,
    provider: providerAddress,
    milestoneAmounts: [SUBMITTED_USDC, PENDING_USDC],
    deadline: Number(block.timestamp) + SETTLE_DEADLINE_SECONDS,
  });
  await providerOperator.escrow.acceptJob(created.jobId);
  // Only the first milestone is delivered; the second must find its way back to the client.
  await providerOperator.escrow.submitMilestone(
    created.jobId,
    0,
    keccak256(stringToHex(`settle-deliverable-${suffix}`)),
  );

  const providerBefore = await providerOperator.usdc.balanceOf(providerAddress);
  const clientBefore = await clientOperator.usdc.balanceOf(clientAddress);
  await testClient.increaseTime({ seconds: EXPIRY_SKIP_SECONDS });
  await testClient.mine({ blocks: 1 });

  const settled = await bystander.escrow.settleExpired(created.jobId);
  const providerDelta = (await providerOperator.usdc.balanceOf(providerAddress)) - providerBefore;
  const clientDelta = (await clientOperator.usdc.balanceOf(clientAddress)) - clientBefore;
  check(
    'settleExpired by a third party pays the submitted milestone to the provider',
    providerDelta === SUBMITTED_AMOUNT && settled.toProvider === SUBMITTED_AMOUNT,
    `delta=${providerDelta} event=${settled.toProvider} expected=${SUBMITTED_AMOUNT}`,
  );
  check(
    'settleExpired refunds the pending milestone to the client',
    clientDelta === PENDING_AMOUNT && settled.toClient === PENDING_AMOUNT,
    `delta=${clientDelta} event=${settled.toClient} expected=${PENDING_AMOUNT}`,
  );

  const job = await clientOperator.escrow.getJob(created.jobId);
  const milestones = await clientOperator.escrow.getMilestones(created.jobId);
  check(
    'settled job is Expired, submitted milestone vested, pending one did not',
    job.status === 'Expired' &&
      milestones[0]?.status === 'Approved' &&
      milestones[1]?.status === 'Pending',
    `status=${job.status} milestones=${milestones.map((m) => m.status).join(',')}`,
  );
}

/** An offer the provider never accepted is cancellable for a full refund. */
export async function runCancelLeg(params: TimeoutLegParams): Promise<void> {
  const { publicClient, clientOperator, check, clientAddress, providerAddress } = params;

  const block = await publicClient.getBlock();
  const balanceBefore = await clientOperator.usdc.balanceOf(clientAddress);
  const created = await clientOperator.escrow.createJob({
    client: clientAddress,
    provider: providerAddress,
    milestoneAmounts: [CANCEL_USDC],
    deadline: Number(block.timestamp) + 7 * 24 * 60 * 60,
  });

  const offered = await clientOperator.escrow.getJob(created.jobId);
  check(
    'a fresh job is an unaccepted offer',
    offered.acceptedAt === 0 && !offered.everSubmitted,
    `acceptedAt=${offered.acceptedAt} everSubmitted=${offered.everSubmitted}`,
  );

  await clientOperator.escrow.cancelJob(created.jobId);
  const cancelled = await clientOperator.escrow.getJob(created.jobId);
  const balanceAfter = await clientOperator.usdc.balanceOf(clientAddress);
  check(
    'cancel before acceptance refunds the client in full',
    cancelled.status === 'Cancelled' &&
      cancelled.refunded === CANCEL_AMOUNT &&
      balanceAfter === balanceBefore,
    `status=${cancelled.status} refunded=${cancelled.refunded} netDelta=${balanceAfter - balanceBefore}`,
  );
}
