import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { createRuntime, type McpEnv, type McpRuntime } from './config.js';
import { registerReadTools } from './tools/read.js';
import { registerWriteTools } from './tools/write.js';

export const SERVER_NAME = 'nexusweb3';
export const SERVER_VERSION = '2.0.0';

export interface CreateServerResult {
  server: McpServer;
  runtime: McpRuntime;
}

/**
 * Build the NexusWeb3 MCP server over an existing runtime.
 * Read tools are always registered; write tools too, but they refuse to run
 * without a hot key so the tool list stays stable between modes.
 */
export function createServer(runtime: McpRuntime): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    {
      instructions:
        'Tools for the NexusWeb3 v2 agent protocol on Base: agent identity, reputation, kill switch, ' +
        'audit log and milestone escrow. Token amounts are integers in base units (USDC has 6 decimals). ' +
        'Writes are signed by the configured hot key acting for NEXUS_PRINCIPAL.',
    },
  );
  registerReadTools(server, runtime);
  registerWriteTools(server, runtime);
  return server;
}

/** Build runtime + server straight from environment variables. */
export function createServerFromEnv(env: McpEnv = process.env): CreateServerResult {
  const runtime = createRuntime(env);
  return { server: createServer(runtime), runtime };
}
