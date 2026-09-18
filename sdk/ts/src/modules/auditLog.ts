import { getContract, type Address, type Hex } from 'viem';
import { AgentAuditLogV2Abi } from '../abis/AgentAuditLogV2.js';
import { eventBigInt, requireEvent, sendWrite, type Context } from '../internal.js';
import {
  decodeActionType,
  encodeActionType,
  type ActionLog,
  type LogActionResult,
  type TxResult,
} from '../types.js';

export interface AuditLogModule {
  /**
   * Append an entry for `agent`. `actionType` is a short label (<= 32 bytes) encoded to
   * bytes32; `dataHash` is any 32-byte commitment to the off-chain payload.
   */
  log(agent: Address, actionType: string, dataHash: Hex, value: bigint): Promise<LogActionResult>;
  logBatch(
    agent: Address,
    actionTypes: readonly string[],
    dataHashes: readonly Hex[],
    values: readonly bigint[],
  ): Promise<TxResult>;
  /** Page through an agent's log, newest entries last. `actionType` comes back decoded. */
  getAgentLogs(agent: Address, offset: bigint, limit: bigint): Promise<ActionLog[]>;
  getLog(logId: bigint): Promise<ActionLog>;
  getLogCount(agent: Address): Promise<bigint>;
  totalLogs(): Promise<bigint>;
  isAuthorizedProtocol(protocol: Address): Promise<boolean>;
}

type RawLog = Readonly<{
  agent: Address;
  caller: Address;
  actionType: Hex;
  dataHash: Hex;
  value: bigint;
  timestamp: number;
  blockNumber: bigint;
}>;

function decodeLog(entry: RawLog): ActionLog {
  const { actionType, ...rest } = entry;
  return { ...rest, actionType: decodeActionType(actionType), actionTypeRaw: actionType };
}

export function createAuditLogModule(ctx: Context): AuditLogModule {
  const address = ctx.addresses.auditLog;
  const reader = getContract({ address, abi: AgentAuditLogV2Abi, client: ctx.publicClient });

  return {
    async log(agent, actionType, dataHash, value) {
      const result = await sendWrite(ctx, address, AgentAuditLogV2Abi, 'log', [
        agent,
        encodeActionType(actionType),
        dataHash,
        value,
      ]);
      const event = requireEvent(AgentAuditLogV2Abi, 'ActionLogged', address, result.receipt.logs);
      return { ...result, logId: eventBigInt(event.args, 'logId') };
    },
    async logBatch(agent, actionTypes, dataHashes, values) {
      return sendWrite(ctx, address, AgentAuditLogV2Abi, 'logBatch', [
        agent,
        actionTypes.map(encodeActionType),
        [...dataHashes],
        [...values],
      ]);
    },
    async getAgentLogs(agent, offset, limit) {
      const entries = await reader.read.getAgentLogs([agent, offset, limit]);
      return entries.map(decodeLog);
    },
    async getLog(logId) {
      return decodeLog(await reader.read.getLog([logId]));
    },
    getLogCount: (agent) => reader.read.getLogCount([agent]),
    totalLogs: () => reader.read.totalLogs(),
    isAuthorizedProtocol: (protocol) => reader.read.isAuthorizedProtocol([protocol]),
  };
}
