import { getContract, type Address } from 'viem';
import { AgentKillSwitchV2Abi } from '../abis/AgentKillSwitchV2.js';
import { toBaseUnits, type UsdcAmount } from '../amount.js';
import { sendWrite, type Context } from '../internal.js';
import type { KillSwitchConfig, TxResult } from '../types.js';

/**
 * Kill-switch configuration is principal-only: every write here must be signed by
 * the agent principal itself, never by an operator (`kill`/`pause`/`unpause` also
 * accept the configured guardian).
 */
export interface KillSwitchModule {
  /** Opt in. `spendingLimit` is human USDC per session, `txLimit` 0 = unlimited. */
  register(spendingLimit: UsdcAmount, txLimit: number, sessionDuration: number): Promise<TxResult>;
  setLimits(spendingLimit: UsdcAmount, txLimit: number, sessionDuration: number): Promise<TxResult>;
  setGuardian(guardian: Address): Promise<TxResult>;
  /** Principal or guardian: block every guarded spend for `agent`. */
  kill(agent: Address): Promise<TxResult>;
  pause(agent: Address): Promise<TxResult>;
  unpause(agent: Address): Promise<TxResult>;
  /** Principal only: undo a kill. */
  resume(): Promise<TxResult>;
  /**
   * Principal only: zero the session counters and start a fresh session. A reset restores
   * spending headroom, so neither an operator nor the restrict-only guardian may call it —
   * the wallet must be the agent principal itself or the call reverts with `NotPrincipal`.
   */
  resetSession(agent: Address): Promise<TxResult>;
  /** !killed && !paused. True for unregistered agents. */
  isActive(agent: Address): Promise<boolean>;
  getConfig(agent: Address): Promise<KillSwitchConfig>;
  /**
   * Spend left in the current session, in base units; uint256 max when unregistered, 0 when the
   * limit was lowered below what the session already spent. Never reverts.
   */
  remainingSpend(agent: Address): Promise<bigint>;
  guardianOf(agent: Address): Promise<Address>;
}

export function createKillSwitchModule(ctx: Context): KillSwitchModule {
  const address = ctx.addresses.killSwitch;
  const reader = getContract({ address, abi: AgentKillSwitchV2Abi, client: ctx.publicClient });

  return {
    async register(spendingLimit, txLimit, sessionDuration) {
      const limit = toBaseUnits(spendingLimit, 'spendingLimit');
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'register', [limit, txLimit, sessionDuration]);
    },
    async setLimits(spendingLimit, txLimit, sessionDuration) {
      const limit = toBaseUnits(spendingLimit, 'spendingLimit');
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'setLimits', [limit, txLimit, sessionDuration]);
    },
    async setGuardian(guardian) {
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'setGuardian', [guardian]);
    },
    async kill(agent) {
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'kill', [agent]);
    },
    async pause(agent) {
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'pause', [agent]);
    },
    async unpause(agent) {
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'unpause', [agent]);
    },
    async resume() {
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'resume', []);
    },
    async resetSession(agent) {
      return sendWrite(ctx, address, AgentKillSwitchV2Abi, 'resetSession', [agent]);
    },
    isActive: (agent) => reader.read.isActive([agent]),
    getConfig: (agent) => reader.read.getConfig([agent]),
    remainingSpend: (agent) => reader.read.remainingSpend([agent]),
    guardianOf: (agent) => reader.read.guardianOf([agent]),
  };
}
