import type { Addresses } from './addresses.js';
import { createContext, type NexusClientConfig } from './internal.js';
import { createAccessModule, type AccessModule } from './modules/access.js';
import { createAuditLogModule, type AuditLogModule } from './modules/auditLog.js';
import { createEscrowModule, type EscrowModule } from './modules/escrow.js';
import { createIdentityModule, type IdentityModule } from './modules/identity.js';
import { createKillSwitchModule, type KillSwitchModule } from './modules/killSwitch.js';
import { createReputationModule, type ReputationModule } from './modules/reputation.js';
import { createUsdcModule, type UsdcModule } from './modules/usdc.js';
import type { NexusPublicClient, NexusWalletClient } from './types.js';

/** Namespaced entry point for the whole v2 stack. */
export interface NexusClient {
  readonly addresses: Addresses;
  readonly publicClient: NexusPublicClient;
  readonly walletClient: NexusWalletClient | undefined;
  readonly access: AccessModule;
  readonly identity: IdentityModule;
  readonly reputation: ReputationModule;
  readonly killSwitch: KillSwitchModule;
  readonly auditLog: AuditLogModule;
  readonly escrow: EscrowModule;
  readonly usdc: UsdcModule;
}

/**
 * Build a client over an already-deployed v2 core.
 *
 * Reads work with `publicClient` alone. Writes need `walletClient`, whose account
 * is either an agent principal or a hot operator key authorized through
 * `access.authorizeOperator`.
 */
export function createNexusClient(config: NexusClientConfig): NexusClient {
  const ctx = createContext(config);
  return {
    addresses: ctx.addresses,
    publicClient: ctx.publicClient,
    walletClient: ctx.walletClient,
    access: createAccessModule(ctx),
    identity: createIdentityModule(ctx),
    reputation: createReputationModule(ctx),
    killSwitch: createKillSwitchModule(ctx),
    auditLog: createAuditLogModule(ctx),
    escrow: createEscrowModule(ctx),
    usdc: createUsdcModule(ctx),
  };
}
