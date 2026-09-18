import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { McpRuntime } from '../config.js';
import { guard, parseAddress, resolveAgent } from '../helpers.js';

const agentArg = z.string().optional().describe('Agent principal address. Defaults to NEXUS_PRINCIPAL.');
const offsetArg = z.number().int().min(0).default(0).describe('Page offset.');

/** Register every read-only tool. These work without NEXUS_PRIVATE_KEY. */
export function registerReadTools(server: McpServer, runtime: McpRuntime): void {
  const { client } = runtime;

  server.registerTool(
    'nexus_identity_get',
    {
      title: 'Get agent identity',
      description: 'Read an agent profile (name, agentURI, type, active flag) and its ERC-8004 link.',
      inputSchema: { agent: agentArg },
    },
    async ({ agent }) =>
      guard(async () => {
        const address = resolveAgent(runtime, agent);
        const [profile, registered, erc8004Id] = await Promise.all([
          client.identity.getAgent(address),
          client.identity.isRegistered(address),
          client.identity.erc8004IdOf(address),
        ]);
        return { agent: address, registered, erc8004Id, profile };
      }),
  );

  server.registerTool(
    'nexus_reputation_get',
    {
      title: 'Get agent reputation',
      description: 'Read the value-weighted score, tier and interaction stats of an agent.',
      inputSchema: { agent: agentArg },
    },
    async ({ agent }) =>
      guard(async () => {
        const address = resolveAgent(runtime, agent);
        const [score, tier, stats] = await Promise.all([
          client.reputation.getScore(address),
          client.reputation.getTier(address),
          client.reputation.getStats(address),
        ]);
        return { agent: address, score, tier, stats };
      }),
  );

  server.registerTool(
    'nexus_escrow_get_job',
    {
      title: 'Get escrow job',
      description: 'Read one escrow job with its milestones. Status comes back as a name, not a number.',
      inputSchema: { jobId: z.number().int().min(0).describe('Job id.') },
    },
    async ({ jobId }) =>
      guard(async () => {
        const id = BigInt(jobId);
        const [job, milestones] = await Promise.all([
          client.escrow.getJob(id),
          client.escrow.getMilestones(id),
        ]);
        return { jobId: id, job, milestones };
      }),
  );

  server.registerTool(
    'nexus_escrow_list_jobs',
    {
      title: 'List escrow jobs',
      description: 'List the job ids an account takes part in, as client or as provider.',
      inputSchema: {
        account: agentArg,
        offset: offsetArg,
        limit: z.number().int().min(1).max(100).default(20).describe('Page size.'),
      },
    },
    async ({ account, offset, limit }) =>
      guard(async () => {
        const address = resolveAgent(runtime, account, 'account');
        const [ids, total] = await Promise.all([
          client.escrow.getJobsOf(address, BigInt(offset), BigInt(limit)),
          client.escrow.jobCountOf(address),
        ]);
        return { account: address, total, jobIds: ids };
      }),
  );

  server.registerTool(
    'nexus_killswitch_status',
    {
      title: 'Get kill-switch status',
      description: 'Read the spending guard for an agent: active flag, session limits and remaining spend.',
      inputSchema: { agent: agentArg },
    },
    async ({ agent }) =>
      guard(async () => {
        const address = resolveAgent(runtime, agent);
        const [active, config, remaining, guardian] = await Promise.all([
          client.killSwitch.isActive(address),
          client.killSwitch.getConfig(address),
          client.killSwitch.remainingSpend(address),
          client.killSwitch.guardianOf(address),
        ]);
        return { agent: address, active, remainingSpend: remaining, guardian, config };
      }),
  );

  server.registerTool(
    'nexus_auditlog_list',
    {
      title: 'List audit-log entries',
      description: "Page an agent's append-only action log. Action types are decoded back to strings.",
      inputSchema: {
        agent: agentArg,
        offset: offsetArg,
        limit: z.number().int().min(1).max(100).default(20).describe('Page size.'),
      },
    },
    async ({ agent, offset, limit }) =>
      guard(async () => {
        const address = resolveAgent(runtime, agent);
        const [entries, count] = await Promise.all([
          client.auditLog.getAgentLogs(address, BigInt(offset), BigInt(limit)),
          client.auditLog.getLogCount(address),
        ]);
        return { agent: address, count, entries };
      }),
  );

  server.registerTool(
    'nexus_access_check_operator',
    {
      title: 'Check operator authorization',
      description: 'Check whether a caller may act for an agent principal, and when that lapses.',
      inputSchema: {
        agent: agentArg,
        caller: z.string().describe('Candidate operator address.'),
      },
    },
    async ({ agent, caller }) =>
      guard(async () => {
        const principal = resolveAgent(runtime, agent);
        const operator = parseAddress(caller, 'caller');
        const [authorized, expiry] = await Promise.all([
          client.access.isOperatorFor(principal, operator),
          client.access.operatorExpiry(principal, operator),
        ]);
        return { agent: principal, operator, authorized, expiry };
      }),
  );
}
