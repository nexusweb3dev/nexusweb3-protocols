import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, getAddress, http, isAddress, type Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { loadAddresses, type Addresses } from '../addresses.js';
import { createNexusClient, type NexusClient } from '../client.js';
import { NexusError, type NexusPublicClient, type NexusWalletClient } from '../types.js';

export interface McpEnv {
  NEXUS_RPC_URL?: string | undefined;
  NEXUS_PRIVATE_KEY?: string | undefined;
  NEXUS_ADDRESSES_JSON?: string | undefined;
  NEXUS_PRINCIPAL?: string | undefined;
}

export interface McpRuntime {
  client: NexusClient;
  addresses: Addresses;
  /** Agent principal the hot key acts for. Undefined in read-only mode. */
  principal: Address | undefined;
  /** Address of the hot key, if one was configured. */
  operator: Address | undefined;
  readOnly: boolean;
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

function readAddressesFile(path: string): Addresses {
  let raw: string;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (error) {
    throw new NexusError(`Cannot read NEXUS_ADDRESSES_JSON at ${path}`, error);
  }
  try {
    return loadAddresses(JSON.parse(raw));
  } catch (error) {
    if (error instanceof NexusError) throw error;
    throw new NexusError(`NEXUS_ADDRESSES_JSON at ${path} is not valid JSON`, error);
  }
}

/** Build the chain clients and the principal identity the tools act for. */
export function createRuntime(env: McpEnv = process.env): McpRuntime {
  const rpcUrl = requireEnv(env, 'NEXUS_RPC_URL');
  const addresses = readAddressesFile(requireEnv(env, 'NEXUS_ADDRESSES_JSON'));
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

  return { client, addresses, principal, operator, readOnly: walletClient === undefined };
}
