import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { assertChainId, createRuntime, type McpEnv, type McpRuntime } from '../src/mcp/config.js';
import { NexusError } from '../src/types.js';

const DEPLOYMENT = {
  chainId: 8453,
  paymentToken: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  AgentAccess: '0x0000000000000000000000000000000000000a11',
  AgentIdentityV2: '0x0000000000000000000000000000000000000a22',
  AgentReputationV2: '0x0000000000000000000000000000000000000a33',
  AgentKillSwitchV2: '0x0000000000000000000000000000000000000a44',
  AgentAuditLogV2: '0x0000000000000000000000000000000000000a55',
  FeeRouter: '0x0000000000000000000000000000000000000a66',
  AgentEscrowV2: '0x0000000000000000000000000000000000000a77',
};

function deploymentPath(body: unknown = DEPLOYMENT): string {
  const path = join(mkdtempSync(join(tmpdir(), 'nexus-mcp-')), 'v2.json');
  writeFileSync(path, JSON.stringify(body), 'utf8');
  return path;
}

function env(extra: Partial<McpEnv> = {}): McpEnv {
  return { NEXUS_RPC_URL: 'http://127.0.0.1:8545', NEXUS_ADDRESSES_JSON: deploymentPath(), ...extra };
}

describe('createRuntime security defaults', () => {
  it('keeps principal writes off unless explicitly enabled', () => {
    expect(createRuntime(env()).allowPrincipalWrites).toBe(false);
    expect(createRuntime(env({ NEXUS_MCP_ALLOW_PRINCIPAL_WRITES: '0' })).allowPrincipalWrites).toBe(false);
    expect(createRuntime(env({ NEXUS_MCP_ALLOW_PRINCIPAL_WRITES: 'yes' })).allowPrincipalWrites).toBe(false);
    expect(createRuntime(env({ NEXUS_MCP_ALLOW_PRINCIPAL_WRITES: '1' })).allowPrincipalWrites).toBe(true);
    expect(createRuntime(env({ NEXUS_MCP_ALLOW_PRINCIPAL_WRITES: 'true' })).allowPrincipalWrites).toBe(true);
  });

  it('carries the deployment chain id and leaves the job cap open by default', () => {
    const runtime = createRuntime(env());
    expect(runtime.expectedChainId).toBe(8453);
    expect(runtime.maxJobAmount).toBeUndefined();
    expect(runtime.readOnly).toBe(true);
  });

  it('reads the job cap as USDC, not base units', () => {
    // "250" is two hundred fifty dollars. A base-unit value copied from an older config would be
    // a millionfold wider cap, which is why the startup banner echoes it back in USDC.
    expect(createRuntime(env({ NEXUS_MCP_MAX_JOB_AMOUNT: '250' })).maxJobAmount).toBe(250_000_000n);
    expect(createRuntime(env({ NEXUS_MCP_MAX_JOB_AMOUNT: '250.50' })).maxJobAmount).toBe(250_500_000n);
    expect(() => createRuntime(env({ NEXUS_MCP_MAX_JOB_AMOUNT: '1.0000001' }))).toThrow(NexusError);
    expect(() => createRuntime(env({ NEXUS_MCP_MAX_JOB_AMOUNT: 'lots' }))).toThrow(NexusError);
    expect(() => createRuntime(env({ NEXUS_MCP_MAX_JOB_AMOUNT: '0' }))).toThrow(NexusError);
  });

  it('rejects a private key that is not 32 bytes of hex', () => {
    expect(() => createRuntime(env({ NEXUS_PRIVATE_KEY: 'not-a-key' }))).toThrow(NexusError);
  });

  it('never echoes the private key in the error it throws', () => {
    const secret = `0x${'ab'.repeat(31)}`; // 31 bytes: rejected
    try {
      createRuntime(env({ NEXUS_PRIVATE_KEY: secret }));
      expect.unreachable('should have thrown');
    } catch (error) {
      expect(String((error as Error).message)).not.toContain('abab');
    }
  });
});

describe('assertChainId', () => {
  const runtimeWith = (expected: number | undefined, actual: number): McpRuntime =>
    ({
      expectedChainId: expected,
      client: { publicClient: { getChainId: async () => actual } },
    }) as unknown as McpRuntime;

  it('passes when the RPC agrees with the deployment', async () => {
    await expect(assertChainId(runtimeWith(8453, 8453))).resolves.toBeUndefined();
  });

  it('refuses to run when the RPC is on another chain', async () => {
    await expect(assertChainId(runtimeWith(8453, 1))).rejects.toThrow(/chain 1.*chain 8453/s);
  });

  it('is a no-op when the deployment records no chain id', async () => {
    await expect(assertChainId(runtimeWith(undefined, 1))).resolves.toBeUndefined();
  });
});
