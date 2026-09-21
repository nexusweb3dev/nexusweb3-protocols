import type {
  Account,
  Address,
  Chain,
  ContractFunctionReturnType,
  Hash,
  Hex,
  PublicClient,
  TransactionReceipt,
  Transport,
  WalletClient,
} from 'viem';
import { hexToString, stringToHex } from 'viem';
import type { AgentAuditLogV2Abi } from './abis/AgentAuditLogV2.js';
import type { AgentEscrowV2Abi } from './abis/AgentEscrowV2.js';
import type { AgentIdentityV2Abi } from './abis/AgentIdentityV2.js';
import type { AgentKillSwitchV2Abi } from './abis/AgentKillSwitchV2.js';
import type { AgentReputationV2Abi } from './abis/AgentReputationV2.js';

/** Public client used for every read and for receipt waiting. */
export type NexusPublicClient = PublicClient<Transport, Chain | undefined>;

/** Wallet client used for writes. Must carry an account (hot operator key or principal). */
export type NexusWalletClient = WalletClient<Transport, Chain | undefined, Account>;

/** Thrown for every SDK-level failure (missing wallet, reverted tx, undecodable event). */
export class NexusError extends Error {
  public override readonly cause?: unknown;

  constructor(message: string, cause?: unknown) {
    super(message);
    this.name = 'NexusError';
    this.cause = cause;
  }
}

/** Result of any state-changing call: the hash plus the mined receipt. */
export interface TxResult {
  hash: Hash;
  receipt: TransactionReceipt;
}

export interface CreateJobResult extends TxResult {
  jobId: bigint;
}

export interface LogActionResult extends TxResult {
  logId: bigint;
}

// ─── Enums ────────────────────────────────────────────────────────────────

export const TIERS = ['BRONZE', 'SILVER', 'GOLD', 'PLATINUM'] as const;
export type Tier = (typeof TIERS)[number];

export const JOB_STATUSES = ['Open', 'Completed', 'Cancelled', 'Disputed', 'Resolved', 'Expired'] as const;
export type JobStatus = (typeof JOB_STATUSES)[number];

export const MILESTONE_STATUSES = ['Pending', 'Submitted', 'Approved'] as const;
export type MilestoneStatus = (typeof MILESTONE_STATUSES)[number];

function decodeEnum<const T extends readonly string[]>(names: T, value: number, label: string): T[number] {
  const name = names[value];
  if (name === undefined) throw new NexusError(`Unknown ${label} enum value ${value}`);
  return name;
}

export function decodeTier(value: number): Tier {
  return decodeEnum(TIERS, value, 'Tier');
}

export function decodeJobStatus(value: number): JobStatus {
  return decodeEnum(JOB_STATUSES, value, 'JobStatus');
}

export function decodeMilestoneStatus(value: number): MilestoneStatus {
  return decodeEnum(MILESTONE_STATUSES, value, 'MilestoneStatus');
}

// ─── bytes32 <-> string ───────────────────────────────────────────────────

/** Encode a short label (<= 32 bytes) as a right-padded bytes32, e.g. "TRADE_EXECUTED". */
export function encodeActionType(actionType: string): Hex {
  return stringToHex(actionType, { size: 32 });
}

/** Inverse of {@link encodeActionType}; trailing zero padding is stripped. */
export function decodeActionType(actionType: Hex): string {
  return hexToString(actionType, { size: 32 });
}

// ─── Contract struct types (derived from the compiled ABIs) ───────────────

export type AgentProfile = ContractFunctionReturnType<typeof AgentIdentityV2Abi, 'view', 'getAgent'>;
export type ReputationStats = ContractFunctionReturnType<typeof AgentReputationV2Abi, 'view', 'getStats'>;
export type KillSwitchConfig = ContractFunctionReturnType<typeof AgentKillSwitchV2Abi, 'view', 'getConfig'>;

type RawActionLog = ContractFunctionReturnType<typeof AgentAuditLogV2Abi, 'view', 'getLog'>;
/** Audit-log entry with `actionType` decoded back to its string label. */
export type ActionLog = Omit<RawActionLog, 'actionType'> & { actionType: string; actionTypeRaw: Hex };

type RawJob = ContractFunctionReturnType<typeof AgentEscrowV2Abi, 'view', 'getJob'>;
/** Escrow job with `status` decoded to a string union. */
export type Job = Omit<RawJob, 'status'> & { status: JobStatus };

type RawMilestone = ContractFunctionReturnType<typeof AgentEscrowV2Abi, 'view', 'getMilestones'>[number];
/** Escrow milestone with `status` decoded to a string union. */
export type Milestone = Omit<RawMilestone, 'status'> & { status: MilestoneStatus };

/** Arguments accepted by `escrow.createJob`. */
export interface CreateJobParams {
  client: Address;
  provider: Address;
  /** Optional dispute arbiter. Omit (or zero address) for the deadline-refund path only. */
  arbiter?: Address;
  /** 1..20 milestone amounts in payment-token units (USDC: 6 decimals). Each must be > 0. */
  milestoneAmounts: readonly bigint[];
  /** Unix seconds; must be now + 1h .. now + 365d. */
  deadline: number;
  /** keccak256 of the off-chain terms document. Defaults to bytes32(0). */
  termsHash?: Hex;
}

/** EIP-2612 signature split, as `createJobWithPermit` expects it. */
export interface PermitSignature {
  v: number;
  r: Hex;
  s: Hex;
}
