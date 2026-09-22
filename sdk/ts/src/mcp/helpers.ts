import { getAddress, isAddress, type Address, type Hex } from 'viem';
import { parseUsdc } from '../amount.js';
import { NexusError } from '../types.js';
import type { McpRuntime } from './config.js';

/** Minimal shape of an MCP tool result; matches `CallToolResult` from the SDK. */
export interface ToolResult {
  [key: string]: unknown;
  content: Array<{ [key: string]: unknown; type: 'text'; text: string }>;
  isError?: boolean;
}

/**
 * Longest fragment of caller- or chain-supplied text echoed back inside an error message.
 * Long enough to recognise what was rejected, short enough that nothing substantial can be
 * smuggled into the model's context through a deliberately malformed argument.
 */
export const MAX_ECHO_LENGTH = 64;

/** Longest error message surfaced to the model, after flattening. */
export const MAX_MESSAGE_LENGTH = 512;

// C0 and C1 control characters, which is also every newline, tab and ANSI escape introducer.
const CONTROL_CHARACTERS = /[\x00-\x1F\x7F-\x9F]/g;

/**
 * Collapse untrusted text to a single printable line and cap it.
 *
 * Tool text lands in an LLM's context as-is, so a value carrying newlines can forge what looks
 * like a fresh instruction, a second tool result or a system line. Stripping control characters
 * removes that shape, and the cap keeps a long payload from crowding out real context.
 */
function flatten(value: string, limit: number): string {
  const single = value.replace(CONTROL_CHARACTERS, ' ').replace(/\s+/g, ' ').trim();
  return single.length <= limit ? single : `${single.slice(0, limit)}…`;
}

/**
 * Render an untrusted fragment for an error message: flattened, capped and JSON-quoted, so it
 * reads unambiguously as data rather than as part of the sentence around it.
 */
export function quoteUntrusted(value: string): string {
  return JSON.stringify(flatten(value, MAX_ECHO_LENGTH));
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

/**
 * Report a failure as a JSON object with the message in a string field.
 *
 * Failures carry the most attacker-reachable text on this surface: a decoded revert reason, an
 * agent name or an agentURI quoted back by viem. Going out as a JSON string field rather than
 * as bare prose means quotes, backslashes and control characters arrive escaped, and the model
 * sees one clearly delimited datum instead of free text it might read as an instruction.
 */
export function fail(error: unknown): ToolResult {
  const raw = error instanceof Error ? error.message : String(error);
  return {
    content: [{ type: 'text', text: toJsonText({ error: flatten(raw, MAX_MESSAGE_LENGTH) }) }],
    isError: true,
  };
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
  if (!isAddress(value)) {
    throw new NexusError(`${label} is not a valid address (got: ${quoteUntrusted(value)})`);
  }
  return getAddress(value);
}

/**
 * Every amount crossing this server is a human USDC string — `"100.50"` is one hundred dollars
 * fifty, never base units. One rule for the whole tool surface, so a model cannot be off by 1e6.
 */
export function parseAmount(value: string, label: string): bigint {
  try {
    return parseUsdc(value, label);
  } catch {
    // parseUsdc echoes the rejected amount verbatim; re-raise with it quoted and capped.
    throw new NexusError(
      `${label} must be a USDC amount in dollars such as "100.50", with at most 6 decimal ` +
        `places (got: ${quoteUntrusted(value)})`,
    );
  }
}

export function parseBytes32(value: string, label: string): Hex {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new NexusError(
      `${label} must be a 0x-prefixed 32-byte hex string (got: ${quoteUntrusted(value)})`,
    );
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
