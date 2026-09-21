#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServerFromEnv } from './server.js';

export { createServer, createServerFromEnv, SERVER_NAME, SERVER_VERSION } from './server.js';
export { createRuntime } from './config.js';
export type { McpEnv, McpRuntime } from './config.js';

async function main(): Promise<void> {
  const { server, runtime } = createServerFromEnv();
  // stdout is the MCP transport; every human-readable line must go to stderr.
  process.stderr.write(
    `nexusweb3 mcp: escrow=${runtime.addresses.escrow} principal=${runtime.principal ?? 'none'} ` +
      `mode=${runtime.readOnly ? 'read-only' : 'read-write'}\n`,
  );
  await server.connect(new StdioServerTransport());
}

const entry = process.argv[1];
const invokedDirectly = entry !== undefined && import.meta.url === pathToFileURL(entry).href;
if (invokedDirectly) {
  main().catch((error: unknown) => {
    process.stderr.write(`nexusweb3 mcp failed to start: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  });
}
