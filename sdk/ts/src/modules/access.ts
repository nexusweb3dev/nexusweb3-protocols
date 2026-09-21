import { getContract, type Address } from 'viem';
import { AgentAccessAbi } from '../abis/AgentAccess.js';
import { sendWrite, type Context } from '../internal.js';
import type { TxResult } from '../types.js';

/** Largest uint48 — an authorization that never expires. */
export const NO_EXPIRY = 281_474_976_710_655;

export interface AccessModule {
  /** Principal authorizes a hot operator key until `expiry` (unix seconds, default {@link NO_EXPIRY}). */
  authorizeOperator(operator: Address, expiry?: number): Promise<TxResult>;
  revokeOperator(operator: Address): Promise<TxResult>;
  /** True when `caller` is `agent` itself or one of its unexpired operators. */
  isOperatorFor(agent: Address, caller: Address): Promise<boolean>;
  /** 0 when `operator` is not authorized for `agent`. */
  operatorExpiry(agent: Address, operator: Address): Promise<number>;
}

export function createAccessModule(ctx: Context): AccessModule {
  const address = ctx.addresses.access;
  const reader = getContract({ address, abi: AgentAccessAbi, client: ctx.publicClient });

  return {
    async authorizeOperator(operator, expiry = NO_EXPIRY) {
      return sendWrite(ctx, address, AgentAccessAbi, 'authorizeOperator', [operator, expiry]);
    },
    async revokeOperator(operator) {
      return sendWrite(ctx, address, AgentAccessAbi, 'revokeOperator', [operator]);
    },
    isOperatorFor: (agent, caller) => reader.read.isOperatorFor([agent, caller]),
    operatorExpiry: (agent, operator) => reader.read.operatorExpiry([agent, operator]),
  };
}
