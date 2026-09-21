import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { NO_EXPIRY } from '../../modules/access.js';
import { NexusError } from '../../types.js';
import type { McpRuntime } from '../config.js';
import { guard, parseAddress, parseAmount, parseBytes32, requireSigner, resolveAgent } from '../helpers.js';

const DEFAULT_JOB_DURATION_SECONDS = 7 * 24 * 60 * 60;

const agentArg = z.string().optional().describe('Agent principal address. Defaults to NEXUS_PRINCIPAL.');
const jobIdArg = z.number().int().min(0).describe('Job id.');
const indexArg = z.number().int().min(0).max(19).describe('Milestone index.');

/** Register every state-changing tool. All of them need NEXUS_PRIVATE_KEY. */
export function registerWriteTools(server: McpServer, runtime: McpRuntime): void {
  const { client } = runtime;

  server.registerTool(
    'nexus_identity_register',
    {
      title: 'Register agent identity',
      description:
        'Register the agent principal in AgentIdentityV2. Free and permanent; the name must be unused.',
      inputSchema: {
        name: z.string().min(1).max(64).describe('Globally unique agent name.'),
        agentURI: z.string().max(512).default('').describe('Metadata JSON URI (endpoints, capabilities).'),
        agentType: z.number().int().min(0).max(10).default(0).describe('Free-form category, 0..10.'),
        agent: agentArg,
      },
    },
    async ({ name, agentURI, agentType, agent }) =>
      guard(async () => {
        requireSigner(runtime);
        const address = resolveAgent(runtime, agent);
        const result = await client.identity.register(address, name, agentURI, agentType);
        return { agent: address, name, txHash: result.hash };
      }),
  );

  server.registerTool(
    'nexus_access_authorize_operator',
    {
      title: 'Authorize an operator',
      description:
        'Authorize a hot key to act for the signing principal in every v2 contract. Signed by the principal itself.',
      inputSchema: {
        operator: z.string().describe('Hot key address to authorize.'),
        expiry: z
          .number()
          .int()
          .min(0)
          .optional()
          .describe('Unix seconds when the authorization lapses. Omit for no expiry.'),
      },
    },
    async ({ operator, expiry }) =>
      guard(async () => {
        requireSigner(runtime);
        const address = parseAddress(operator, 'operator');
        const result = await client.access.authorizeOperator(address, expiry ?? NO_EXPIRY);
        return { operator: address, expiry: expiry ?? NO_EXPIRY, txHash: result.hash };
      }),
  );

  server.registerTool(
    'nexus_escrow_create_job',
    {
      title: 'Create an escrow job',
      description:
        'Fund a milestone job. Pulls the total from the client principal, which must have approved AgentEscrowV2 first.',
      inputSchema: {
        provider: z.string().describe('Provider (payee) principal address.'),
        milestoneAmounts: z
          .array(z.string())
          .min(1)
          .max(20)
          .describe('Milestone amounts in token base units, e.g. ["100000000"] for 100 USDC.'),
        arbiter: z.string().optional().describe('Optional dispute arbiter. Omit for deadline-refund only.'),
        deadline: z.number().int().optional().describe('Unix seconds. Defaults to 7 days from the latest block.'),
        termsHash: z.string().optional().describe('keccak256 of the off-chain terms document.'),
        client: agentArg,
      },
    },
    async ({ provider, milestoneAmounts, arbiter, deadline, termsHash, client: clientArg }) =>
      guard(async () => {
        requireSigner(runtime);
        const principal = resolveAgent(runtime, clientArg, 'client');
        const providerAddress = parseAddress(provider, 'provider');
        const amounts = milestoneAmounts.map((value, i) => parseAmount(value, `milestoneAmounts[${i}]`));
        const total = amounts.reduce((sum, value) => sum + value, 0n);

        const [allowance, balance, block] = await Promise.all([
          client.usdc.allowance(principal, client.escrow.address),
          client.usdc.balanceOf(principal),
          runtime.client.publicClient.getBlock(),
        ]);
        if (balance < total) {
          throw new NexusError(`Client ${principal} holds ${balance} but the job needs ${total}`);
        }
        if (allowance < total) {
          throw new NexusError(
            `Client ${principal} has approved ${allowance} to the escrow but the job needs ${total}. ` +
              'Approve from the principal key first.',
          );
        }

        const result = await client.escrow.createJob({
          client: principal,
          provider: providerAddress,
          ...(arbiter ? { arbiter: parseAddress(arbiter, 'arbiter') } : {}),
          milestoneAmounts: amounts,
          deadline: deadline ?? Number(block.timestamp) + DEFAULT_JOB_DURATION_SECONDS,
          ...(termsHash ? { termsHash: parseBytes32(termsHash, 'termsHash') } : {}),
        });
        return { jobId: result.jobId, total, milestones: amounts.length, txHash: result.hash };
      }),
  );

  server.registerTool(
    'nexus_escrow_submit_milestone',
    {
      title: 'Submit a milestone',
      description: 'Provider side: attach a deliverable hash to a milestone and mark it submitted.',
      inputSchema: {
        jobId: jobIdArg,
        index: indexArg,
        deliverableHash: z.string().describe('32-byte hex commitment to the deliverable.'),
      },
    },
    async ({ jobId, index, deliverableHash }) =>
      guard(async () => {
        requireSigner(runtime);
        const hash = parseBytes32(deliverableHash, 'deliverableHash');
        const result = await client.escrow.submitMilestone(BigInt(jobId), index, hash);
        return { jobId, index, txHash: result.hash };
      }),
  );

  server.registerTool(
    'nexus_escrow_claim_approval',
    {
      title: 'Claim an ignored milestone',
      description:
        'Provider side: approve a milestone the client left Submitted past the 7-day review window. Client silence counts as acceptance.',
      inputSchema: { jobId: jobIdArg, index: indexArg },
    },
    async ({ jobId, index }) =>
      guard(async () => {
        requireSigner(runtime);
        const result = await client.escrow.claimApproval(BigInt(jobId), index);
        const job = await client.escrow.getJob(BigInt(jobId));
        return { jobId, index, jobStatus: job.status, txHash: result.hash };
      }),
  );

  server.registerTool(
    'nexus_escrow_approve_milestone',
    {
      title: 'Approve a milestone',
      description:
        'Client side: release a milestone to the provider, writing reputation and the audit log in the same transaction.',
      inputSchema: { jobId: jobIdArg, index: indexArg },
    },
    async ({ jobId, index }) =>
      guard(async () => {
        requireSigner(runtime);
        const result = await client.escrow.approveMilestone(BigInt(jobId), index);
        const job = await client.escrow.getJob(BigInt(jobId));
        return { jobId, index, jobStatus: job.status, txHash: result.hash };
      }),
  );
}
