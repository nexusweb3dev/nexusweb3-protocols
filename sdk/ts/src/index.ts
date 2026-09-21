export { BASE_ERC8004_IDENTITY_REGISTRY, loadAddresses, readChainId } from './addresses.js';
export type { Addresses, DeploymentJson } from './addresses.js';
export { createNexusClient } from './client.js';
export type { NexusClient } from './client.js';
export type { NexusClientConfig } from './internal.js';
export { NO_EXPIRY } from './modules/access.js';
export type { AccessModule } from './modules/access.js';
export type { AuditLogModule } from './modules/auditLog.js';
export type { EscrowModule } from './modules/escrow.js';
export type { IdentityModule } from './modules/identity.js';
export type { KillSwitchModule } from './modules/killSwitch.js';
export type { ReputationModule } from './modules/reputation.js';
export type { UsdcModule } from './modules/usdc.js';
export {
  buildPermitTypedData,
  PERMIT_TYPES,
  signPermit,
  USDC_EIP712_VERSION,
} from './permit.js';
export type {
  BuildPermitTypedDataParams,
  PermitMessage,
  PermitTypedData,
  SignedPermit,
  SignPermitParams,
} from './permit.js';
export {
  decodeActionType,
  decodeJobStatus,
  decodeMilestoneStatus,
  decodeTier,
  encodeActionType,
  JOB_STATUSES,
  MILESTONE_STATUSES,
  NexusError,
  TIERS,
} from './types.js';
export type {
  ActionLog,
  AgentProfile,
  CreateJobParams,
  CreateJobResult,
  Job,
  JobStatus,
  KillSwitchConfig,
  LogActionResult,
  Milestone,
  MilestoneStatus,
  NexusPublicClient,
  NexusWalletClient,
  PermitSignature,
  ReputationStats,
  Tier,
  TxResult,
} from './types.js';
export {
  AgentAccessAbi,
  AgentAuditLogV2Abi,
  AgentEscrowV2Abi,
  AgentIdentityV2Abi,
  AgentKillSwitchV2Abi,
  AgentReputationV2Abi,
  erc20Abi,
  FeeRouterAbi,
} from './abis/index.js';
