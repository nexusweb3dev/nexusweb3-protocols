import { getContract, type Address } from 'viem';
import { AgentIdentityV2Abi } from '../abis/AgentIdentityV2.js';
import { sendWrite, type Context } from '../internal.js';
import type { AgentProfile, TxResult } from '../types.js';

export interface IdentityModule {
  /**
   * Register `agent` (the principal). Callable by the principal or one of its operators. `name` is
   * restricted to lowercase `a-z`, digits, `-`, `_` and `.` so two names that look alike cannot be
   * different byte strings; anything else reverts with `InvalidName`.
   */
  register(agent: Address, name: string, agentURI: string, agentType: number): Promise<TxResult>;
  setAgentURI(agent: Address, agentURI: string): Promise<TxResult>;
  setAgentType(agent: Address, agentType: number): Promise<TxResult>;
  deactivate(agent: Address): Promise<TxResult>;
  reactivate(agent: Address): Promise<TxResult>;
  /**
   * Link an ERC-8004 agentId owned by `agent` in the configured registry. `agentId` must be
   * non-zero — `0` reverts with `InvalidERC8004Id` rather than recording an empty link.
   */
  linkERC8004(agent: Address, agentId: bigint): Promise<TxResult>;
  unlinkERC8004(agent: Address): Promise<TxResult>;
  getAgent(agent: Address): Promise<AgentProfile>;
  isRegistered(agent: Address): Promise<boolean>;
  /** Zero address when the name is free. */
  getAgentByName(name: string): Promise<Address>;
  /** 0 when no ERC-8004 id is linked, or when the link predates the current {@link registryEpoch}. */
  erc8004IdOf(agent: Address): Promise<bigint>;
  /** Zero address when unlinked, or when the link predates the current {@link registryEpoch}. */
  agentOfERC8004(agentId: bigint): Promise<Address>;
  /**
   * Bumped every time the owner points the contract at another ERC-8004 registry. Links written
   * under an earlier epoch read as absent, so a swapped registry cannot inherit stale ownership.
   */
  registryEpoch(): Promise<number>;
  erc8004Registry(): Promise<Address>;
  agentCount(): Promise<bigint>;
}

export function createIdentityModule(ctx: Context): IdentityModule {
  const address = ctx.addresses.identity;
  const reader = getContract({ address, abi: AgentIdentityV2Abi, client: ctx.publicClient });

  return {
    async register(agent, name, agentURI, agentType) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'register', [agent, name, agentURI, agentType]);
    },
    async setAgentURI(agent, agentURI) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'setAgentURI', [agent, agentURI]);
    },
    async setAgentType(agent, agentType) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'setAgentType', [agent, agentType]);
    },
    async deactivate(agent) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'deactivate', [agent]);
    },
    async reactivate(agent) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'reactivate', [agent]);
    },
    async linkERC8004(agent, agentId) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'linkERC8004', [agent, agentId]);
    },
    async unlinkERC8004(agent) {
      return sendWrite(ctx, address, AgentIdentityV2Abi, 'unlinkERC8004', [agent]);
    },
    getAgent: (agent) => reader.read.getAgent([agent]),
    isRegistered: (agent) => reader.read.isRegistered([agent]),
    getAgentByName: (name) => reader.read.getAgentByName([name]),
    erc8004IdOf: (agent) => reader.read.erc8004IdOf([agent]),
    agentOfERC8004: (agentId) => reader.read.agentOfERC8004([agentId]),
    registryEpoch: () => reader.read.registryEpoch(),
    erc8004Registry: () => reader.read.erc8004Registry(),
    agentCount: () => reader.read.agentCount(),
  };
}
