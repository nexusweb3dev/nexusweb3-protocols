import { getContract, zeroAddress, zeroHash, type Address, type Hex } from 'viem';
import { AgentEscrowV2Abi } from '../abis/AgentEscrowV2.js';
import { toBaseUnits } from '../amount.js';
import { eventBigInt, requireEvent, sendWrite, type Context } from '../internal.js';
import {
  decodeJobStatus,
  decodeMilestoneStatus,
  type CreateJobParams,
  type CreateJobResult,
  type Job,
  type Milestone,
  type PermitSignature,
  type SettleExpiredResult,
  type TxResult,
  type WithdrawClaimableResult,
} from '../types.js';

type RawJob = Readonly<{
  client: Address;
  provider: Address;
  arbiter: Address;
  total: bigint;
  released: bigint;
  refunded: bigint;
  deadline: number;
  createdAt: number;
  acceptedAt: number;
  disputedAt: number;
  milestoneCount: number;
  approvedCount: number;
  everSubmitted: boolean;
  status: number;
  termsHash: Hex;
}>;

type RawMilestone = Readonly<{
  amount: bigint;
  deliverableHash: Hex;
  submittedAt: number;
  rejections: number;
  status: number;
}>;

/** Solidity `CreateParams`, with the SDK's optional fields filled in. */
interface CreateParamsTuple {
  client: Address;
  provider: Address;
  arbiter: Address;
  milestoneAmounts: readonly bigint[];
  deadline: number;
  termsHash: Hex;
}

function toCreateParams(params: CreateJobParams): CreateParamsTuple {
  return {
    client: params.client,
    provider: params.provider,
    arbiter: params.arbiter ?? zeroAddress,
    milestoneAmounts: params.milestoneAmounts.map((amount, index) =>
      toBaseUnits(amount, `milestoneAmounts[${index}]`),
    ),
    deadline: params.deadline,
    termsHash: params.termsHash ?? zeroHash,
  };
}

function decodeJob(job: RawJob): Job {
  const { status, ...rest } = job;
  return { ...rest, status: decodeJobStatus(status) };
}

function decodeMilestone(milestone: RawMilestone): Milestone {
  const { status, ...rest } = milestone;
  return { ...rest, status: decodeMilestoneStatus(status) };
}

export interface EscrowModule {
  readonly address: Address;
  /** Client side: pulls `sum(milestoneAmounts)` of the payment token from `params.client`. */
  createJob(params: CreateJobParams): Promise<CreateJobResult>;
  /** Same, but consumes an EIP-2612 permit first so no prior `approve` is needed. */
  createJobWithPermit(
    params: CreateJobParams,
    permitDeadline: bigint,
    signature: PermitSignature,
  ): Promise<CreateJobResult>;
  /**
   * Provider side: bind the provider to the offer. A job stays a mere offer until this lands —
   * `submitMilestone`, `approveMilestone` and `dispute` all revert with `NotAccepted` before it,
   * and the client may cancel for a full refund. Must happen before the job deadline.
   */
  acceptJob(jobId: bigint): Promise<TxResult>;
  submitMilestone(jobId: bigint, index: number, deliverableHash: Hex): Promise<TxResult>;
  /** Provider side: take a milestone the client left Submitted past the review window. */
  claimApproval(jobId: bigint, index: number): Promise<TxResult>;
  approveMilestone(jobId: bigint, index: number): Promise<TxResult>;
  /** Client side, inside the review window only; at most {@link EscrowModule.maxRejections} per milestone. */
  rejectMilestone(jobId: bigint, index: number, reasonHash?: Hex): Promise<TxResult>;
  /** Client side: full refund. Only before acceptance, or after it while nothing was ever submitted. */
  cancelJob(jobId: bigint): Promise<TxResult>;
  /** Either party; needs an arbiter on the job and an accepted job. */
  dispute(jobId: bigint, reasonHash?: Hex): Promise<TxResult>;
  /** Arbiter only: split the remaining balance, `providerBps` out of 10_000 to the provider. */
  resolve(jobId: bigint, providerBps: number): Promise<TxResult>;
  /**
   * Anyone, once the job expired (Open past {@link EscrowModule.expiryOf}) or a dispute went
   * unresolved for {@link EscrowModule.disputeGrace}. Every Submitted milestone vests to the
   * provider, every Pending one refunds the client.
   */
  settleExpired(jobId: bigint): Promise<SettleExpiredResult>;
  /**
   * Sweep funds parked after a failed payout. Callable by `account` itself or one of its
   * operators; `to` is where the tokens land and must not be the zero address.
   */
  withdrawClaimable(account: Address, to: Address): Promise<WithdrawClaimableResult>;
  getJob(jobId: bigint): Promise<Job>;
  getMilestones(jobId: bigint): Promise<Milestone[]>;
  getJobsOf(account: Address, offset: bigint, limit: bigint): Promise<readonly bigint[]>;
  jobCountOf(account: Address): Promise<bigint>;
  jobCount(): Promise<bigint>;
  /** max(deadline, last submission + review window) — the moment `settleExpired` opens. */
  expiryOf(jobId: bigint): Promise<number>;
  claimable(account: Address): Promise<bigint>;
  feeBps(): Promise<bigint>;
  paymentToken(): Promise<Address>;
  /** Seconds a client may leave a Submitted milestone unreviewed before the provider can claim it. */
  reviewWindow(): Promise<bigint>;
  /** Seconds a Disputed job waits for its arbiter before anyone may `settleExpired` it. */
  disputeGrace(): Promise<bigint>;
  /** Rejections a single milestone tolerates before resubmission is refused. */
  maxRejections(): Promise<number>;
  /** Reputation entries one client/provider pair can generate, so a pair cannot farm score. */
  maxReputationPerPair(): Promise<bigint>;
  /** Settlement value below which no reputation is written at all, so dust jobs cannot farm score. */
  minReputationValue(): Promise<bigint>;
}

export function createEscrowModule(ctx: Context): EscrowModule {
  const address = ctx.addresses.escrow;
  const reader = getContract({ address, abi: AgentEscrowV2Abi, client: ctx.publicClient });

  const withJobId = (result: TxResult): CreateJobResult => {
    const event = requireEvent(AgentEscrowV2Abi, 'JobCreated', address, result.receipt.logs);
    return { ...result, jobId: eventBigInt(event.args, 'jobId') };
  };

  return {
    address,
    async createJob(params) {
      return withJobId(await sendWrite(ctx, address, AgentEscrowV2Abi, 'createJob', [toCreateParams(params)]));
    },
    async createJobWithPermit(params, permitDeadline, signature) {
      const result = await sendWrite(ctx, address, AgentEscrowV2Abi, 'createJobWithPermit', [
        toCreateParams(params),
        permitDeadline,
        signature.v,
        signature.r,
        signature.s,
      ]);
      return withJobId(result);
    },
    async acceptJob(jobId) {
      const result = await sendWrite(ctx, address, AgentEscrowV2Abi, 'acceptJob', [jobId]);
      // Proves the ABI and the deployed contract agree on the lifecycle, same as createJob.
      requireEvent(AgentEscrowV2Abi, 'JobAccepted', address, result.receipt.logs);
      return result;
    },
    async submitMilestone(jobId, index, deliverableHash) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'submitMilestone', [jobId, index, deliverableHash]);
    },
    async claimApproval(jobId, index) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'claimApproval', [jobId, index]);
    },
    async approveMilestone(jobId, index) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'approveMilestone', [jobId, index]);
    },
    async rejectMilestone(jobId, index, reasonHash = zeroHash) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'rejectMilestone', [jobId, index, reasonHash]);
    },
    async cancelJob(jobId) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'cancelJob', [jobId]);
    },
    async dispute(jobId, reasonHash = zeroHash) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'dispute', [jobId, reasonHash]);
    },
    async resolve(jobId, providerBps) {
      return sendWrite(ctx, address, AgentEscrowV2Abi, 'resolve', [jobId, providerBps]);
    },
    async settleExpired(jobId) {
      const result = await sendWrite(ctx, address, AgentEscrowV2Abi, 'settleExpired', [jobId]);
      const event = requireEvent(AgentEscrowV2Abi, 'JobExpired', address, result.receipt.logs);
      return {
        ...result,
        toProvider: eventBigInt(event.args, 'toProvider'),
        toClient: eventBigInt(event.args, 'toClient'),
      };
    },
    async withdrawClaimable(account, to) {
      const result = await sendWrite(ctx, address, AgentEscrowV2Abi, 'withdrawClaimable', [account, to]);
      const event = requireEvent(AgentEscrowV2Abi, 'ClaimableWithdrawn', address, result.receipt.logs);
      return { ...result, amount: eventBigInt(event.args, 'amount') };
    },
    async getJob(jobId) {
      return decodeJob(await reader.read.getJob([jobId]));
    },
    async getMilestones(jobId) {
      const milestones = await reader.read.getMilestones([jobId]);
      return milestones.map(decodeMilestone);
    },
    getJobsOf: (account, offset, limit) => reader.read.getJobsOf([account, offset, limit]),
    jobCountOf: (account) => reader.read.jobCountOf([account]),
    jobCount: () => reader.read.jobCount(),
    expiryOf: (jobId) => reader.read.expiryOf([jobId]),
    claimable: (account) => reader.read.claimable([account]),
    feeBps: () => reader.read.feeBps(),
    paymentToken: () => reader.read.paymentToken(),
    reviewWindow: () => reader.read.REVIEW_WINDOW(),
    disputeGrace: () => reader.read.DISPUTE_GRACE(),
    maxRejections: () => reader.read.MAX_REJECTIONS(),
    maxReputationPerPair: () => reader.read.MAX_REPUTATION_PER_PAIR(),
    minReputationValue: () => reader.read.MIN_REPUTATION_VALUE(),
  };
}
