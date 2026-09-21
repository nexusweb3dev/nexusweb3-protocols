import { getContract, type Address } from 'viem';
import { AgentIdentityV2Abi } from '../abis/AgentIdentityV2.js';
import { sendWrite, type Context } from '../internal.js';
import type { AgentProfile, TxResult } from '../types.js';

export interface IdentityModule {
  /** Register `agent` (the principal). Callable by the principal or one of its operators. */
  register(agent: Address, name: string, agentURI: string, agentType: number): Promise<TxResult>;
  setAgentURI(agent: Address, agentURI: string): Promise<TxResult>;
  setAgentType(agent: Address, agentType: number): Promise<TxResult>;
  deactivate(agent: Address): Promise<TxResult>;
  reactivate(agent: Address): Promise<TxResult>;
  /** Link an ERC-8004 agentId owned by `agent` in the configured registry. */
  linkERC8004(agent: Address, agentId: bigint): Promise<TxResult>;
  unlinkERC8004(agent: Address): Promise<TxResult>;
  getAgent(agent: Address): Promise<AgentProfile>;
  isRegistered(agent: Address): Promise<boolean>;
  /** Zero address when the name is free. */
  getAgentByName(name: string): Promise<Address>;
  /** 0 when no ERC-8004 id is linked. */
  erc8004IdOf(agent: Address): Promise<bigint>;
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
    agentCount: () => reader.read.agentCount(),
  };
}
