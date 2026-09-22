import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, getAddress, http, isAddress, type Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { loadAddresses, readChainId, type Addresses } from '../addresses.js';
import { parseUsdc } from '../amount.js';
import { createNexusClient, type NexusClient } from '../client.js';
import { NexusError, type NexusPublicClient, type NexusWalletClient } from '../types.js';

export interface McpEnv {
  NEXUS_RPC_URL?: string | undefined;
  NEXUS_PRIVATE_KEY?: string | undefined;
  NEXUS_ADDRESSES_JSON?: string | undefined;
  NEXUS_PRINCIPAL?: string | undefined;
  /** "1"/"true" registers the tools that must be signed by the agent principal itself. */
  NEXUS_MCP_ALLOW_PRINCIPAL_WRITES?: string | undefined;
  /** Upper bound on the total of one escrow job, as a human USDC amount ("250.00"). */
  NEXUS_MCP_MAX_JOB_AMOUNT?: string | undefined;
}

export interface McpRuntime {
  client: NexusClient;
  addresses: Addresses;
  /** Agent principal the hot key acts for. Undefined in read-only mode. */
  principal: Address | undefined;
  /** Address of the hot key, if one was configured. */
  operator: Address | undefined;
  readOnly: boolean;
  /**
   * Chain id recorded in the deployment JSON, when it carries one.
   * {@link assertChainId} refuses to run when the RPC disagrees.
   */
  expectedChainId: number | undefined;
  /**
   * Whether tools that only the agent principal can sign are exposed at all.
   * Off by default: an LLM driving this server reads untrusted on-chain text, and
   * `authorizeOperator` would let a prompt injection hand the principal to an
   * attacker's key permanently.
   */
  allowPrincipalWrites: boolean;
  /** Cap on the total of one escrow job, in base units. Undefined means uncapped. */
  maxJobAmount: bigint | undefined;
}

function requireEnv(env: McpEnv, key: 'NEXUS_RPC_URL' | 'NEXUS_ADDRESSES_JSON'): string {
  const value = env[key];
  if (!value || value.trim() === '') {
    throw new NexusError(`${key} is required to start the NexusWeb3 MCP server`);
  }
  return value;
}

function normalizePrivateKey(raw: string): `0x${string}` {
  const key = raw.startsWith('0x') ? raw : `0x${raw}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) {
    throw new NexusError('NEXUS_PRIVATE_KEY must be a 32-byte hex private key');
  }
  return key as `0x${string}`;
}

interface Deployment {
  addresses: Addresses;
  chainId: number | undefined;
}

function readAddressesFile(path: string): Deployment {
  let raw: string;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (error) {
    throw new NexusError(`Cannot read NEXUS_ADDRESSES_JSON at ${path}`, error);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new NexusError(`NEXUS_ADDRESSES_JSON at ${path} is not valid JSON`, error);
  }
  return { addresses: loadAddresses(parsed), chainId: readChainId(parsed) };
}

function readFlag(value: string | undefined): boolean {
  const raw = value?.trim().toLowerCase();
  return raw === '1' || raw === 'true';
}

/**
 * Read the job cap. It is a human USDC amount like every other amount on this server; the
 * startup banner echoes it in USDC so a value copied from an older base-unit config — which
 * would silently widen the cap a millionfold — is visible on the first line of output.
 */
function readMaxJobAmount(value: string | undefined): bigint | undefined {
  const raw = value?.trim();
  if (!raw) return undefined;
  const parsed = parseUsdc(raw, 'NEXUS_MCP_MAX_JOB_AMOUNT');
  if (parsed <= 0n) throw new NexusError('NEXUS_MCP_MAX_JOB_AMOUNT must be greater than 0');
  return parsed;
}

/**
 * Refuse to keep running when the RPC endpoint is not the chain the deployment
 * JSON was written for. Without this a swapped or malicious `NEXUS_RPC_URL`
 * makes the hot key sign against whatever contracts sit at those addresses on
 * another chain.
 */
export async function assertChainId(runtime: McpRuntime): Promise<void> {
  if (runtime.expectedChainId === undefined) return;
  const actual = await runtime.client.publicClient.getChainId();
  if (actual !== runtime.expectedChainId) {
    throw new NexusError(
      `Refusing to start: NEXUS_RPC_URL reports chain ${actual}, but the deployment JSON ` +
        `declares chain ${runtime.expectedChainId}.`,
    );
  }
}

/** Build the chain clients and the principal identity the tools act for. */
export function createRuntime(env: McpEnv = process.env): McpRuntime {
  const rpcUrl = requireEnv(env, 'NEXUS_RPC_URL');
  const { addresses, chainId } = readAddressesFile(requireEnv(env, 'NEXUS_ADDRESSES_JSON'));
  const publicClient = createPublicClient({ transport: http(rpcUrl) }) as NexusPublicClient;

  let walletClient: NexusWalletClient | undefined;
  let operator: Address | undefined;
  if (env.NEXUS_PRIVATE_KEY && env.NEXUS_PRIVATE_KEY.trim() !== '') {
    const account = privateKeyToAccount(normalizePrivateKey(env.NEXUS_PRIVATE_KEY.trim()));
    operator = account.address;
    walletClient = createWalletClient({ account, transport: http(rpcUrl) }) as NexusWalletClient;
  }

  let principal: Address | undefined = operator;
  const configured = env.NEXUS_PRINCIPAL?.trim();
  if (configured) {
    if (!isAddress(configured)) {
      throw new NexusError(`NEXUS_PRINCIPAL is not a valid address: ${configured}`);
    }
    principal = getAddress(configured);
  }

  const client = walletClient
    ? createNexusClient({ publicClient, walletClient, addresses })
    : createNexusClient({ publicClient, addresses });

  return {
    client,
    addresses,
    principal,
    operator,
    readOnly: walletClient === undefined,
    expectedChainId: chainId,
    allowPrincipalWrites: readFlag(env.NEXUS_MCP_ALLOW_PRINCIPAL_WRITES),
    maxJobAmount: readMaxJobAmount(env.NEXUS_MCP_MAX_JOB_AMOUNT),
  };
}
