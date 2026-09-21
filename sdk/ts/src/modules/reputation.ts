import { getContract, type Address } from 'viem';
import { AgentReputationV2Abi } from '../abis/AgentReputationV2.js';
import type { Context } from '../internal.js';
import { decodeTier, type ReputationStats, type Tier } from '../types.js';

export interface ReputationModule {
  /** Value-weighted score; 0 for an agent with no recorded interactions. */
  getScore(agent: Address): Promise<bigint>;
  /** Score bucket as a string: BRONZE < 200, SILVER >= 200, GOLD >= 500, PLATINUM >= 1000. */
  getTier(agent: Address): Promise<Tier>;
  getStats(agent: Address): Promise<ReputationStats>;
  isAuthorizedProtocol(protocol: Address): Promise<boolean>;
}

export function createReputationModule(ctx: Context): ReputationModule {
  const reader = getContract({
    address: ctx.addresses.reputation,
    abi: AgentReputationV2Abi,
    client: ctx.publicClient,
  });

  return {
    getScore: (agent) => reader.read.getScore([agent]),
    async getTier(agent) {
      return decodeTier(await reader.read.getTier([agent]));
    },
    getStats: (agent) => reader.read.getStats([agent]),
    isAuthorizedProtocol: (protocol) => reader.read.isAuthorizedProtocol([protocol]),
  };
}
