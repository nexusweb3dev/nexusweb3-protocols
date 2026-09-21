import { getAddress, isAddress, type Address, type Hex } from 'viem';
import { NexusError } from '../types.js';
import type { McpRuntime } from './config.js';

/** Minimal shape of an MCP tool result; matches `CallToolResult` from the SDK. */
export interface ToolResult {
  [key: string]: unknown;
  content: Array<{ [key: string]: unknown; type: 'text'; text: string }>;
  isError?: boolean;
}

function replacer(_key: string, value: unknown): unknown {
  return typeof value === 'bigint' ? value.toString() : value;
}

export function toJsonText(data: unknown): string {
  return JSON.stringify(data, replacer, 2);
}

export function ok(data: unknown): ToolResult {
  return { content: [{ type: 'text', text: toJsonText(data) }] };
}

export function fail(error: unknown): ToolResult {
  const message = error instanceof Error ? error.message : String(error);
  return { content: [{ type: 'text', text: message }], isError: true };
}

/** Run a tool body, turning any throw into an `isError` result instead of a transport error. */
export async function guard(run: () => Promise<unknown>): Promise<ToolResult> {
  try {
    return ok(await run());
  } catch (error) {
    return fail(error);
  }
}

export function parseAddress(value: string, label: string): Address {
  if (!isAddress(value)) throw new NexusError(`${label} is not a valid address: ${value}`);
  return getAddress(value);
}

export function parseAmount(value: string, label: string): bigint {
  if (!/^\d+$/.test(value)) {
    throw new NexusError(`${label} must be an integer in token base units (USDC: 6 decimals), got "${value}"`);
  }
  return BigInt(value);
}

export function parseBytes32(value: string, label: string): Hex {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new NexusError(`${label} must be a 0x-prefixed 32-byte hex string`);
  }
  return value as Hex;
}

/** The agent this server acts for: the explicit argument, else NEXUS_PRINCIPAL, else the hot key. */
export function resolveAgent(runtime: McpRuntime, provided: string | undefined, label = 'agent'): Address {
  if (provided) return parseAddress(provided, label);
  if (!runtime.principal) {
    throw new NexusError(
      `No ${label} given and no NEXUS_PRINCIPAL / NEXUS_PRIVATE_KEY configured to default to.`,
    );
  }
  return runtime.principal;
}

export function requireSigner(runtime: McpRuntime): void {
  if (runtime.readOnly) {
    throw new NexusError('This tool writes on chain; set NEXUS_PRIVATE_KEY to enable it.');
  }
}
