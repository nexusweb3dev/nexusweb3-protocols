import { getAddress, isAddress, type Address } from 'viem';
import { NexusError } from './types.js';

/** Canonical ERC-8004 Identity Registry on Base mainnet. */
export const BASE_ERC8004_IDENTITY_REGISTRY: Address = '0x8004A169FB4a3325136EB29fA0ceB6D2e539a432';

/** Every contract address the SDK talks to. */
export interface Addresses {
  access: Address;
  identity: Address;
  reputation: Address;
  killSwitch: Address;
  auditLog: Address;
  feeRouter: Address;
  escrow: Address;
  paymentToken: Address;
}

/** Shape of `deployments/v2-<chainId>.json` as written by `script/v2/DeployCore.s.sol`. */
export interface DeploymentJson {
  chainId?: number;
  owner?: string;
  treasury?: string;
  paymentToken: string;
  AgentAccess: string;
  AgentIdentityV2: string;
  AgentReputationV2: string;
  AgentKillSwitchV2: string;
  AgentAuditLogV2: string;
  FeeRouter: string;
  AgentEscrowV2: string;
}

const FIELDS: ReadonlyArray<readonly [keyof Addresses, keyof DeploymentJson]> = [
  ['access', 'AgentAccess'],
  ['identity', 'AgentIdentityV2'],
  ['reputation', 'AgentReputationV2'],
  ['killSwitch', 'AgentKillSwitchV2'],
  ['auditLog', 'AgentAuditLogV2'],
  ['feeRouter', 'FeeRouter'],
  ['escrow', 'AgentEscrowV2'],
  ['paymentToken', 'paymentToken'],
];

function requireAddress(value: unknown, key: string): Address {
  if (typeof value !== 'string' || !isAddress(value)) {
    throw new NexusError(`Deployment JSON field "${key}" is not a valid address: ${String(value)}`);
  }
  return getAddress(value);
}

/**
 * Map a parsed `deployments/v2-*.json` object onto {@link Addresses}.
 * Throws {@link NexusError} when a field is missing or malformed.
 */
export function loadAddresses(json: unknown): Addresses {
  if (typeof json !== 'object' || json === null) {
    throw new NexusError('Deployment JSON must be an object');
  }
  const record = json as Record<string, unknown>;
  const partial: Partial<Record<keyof Addresses, Address>> = {};
  for (const [field, key] of FIELDS) {
    partial[field] = requireAddress(record[key], key);
  }
  return partial as Addresses;
}

/** Chain id recorded in a deployment JSON, when present. */
export function readChainId(json: unknown): number | undefined {
  if (typeof json !== 'object' || json === null) return undefined;
  const value = (json as Record<string, unknown>).chainId;
  return typeof value === 'number' ? value : undefined;
}
