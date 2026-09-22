/**
 * Permit leg of the e2e: EIP-2612 `permit` + `createJobWithPermit` with no prior approve.
 *
 * `script/v2/DeployLocal.s.sol` funds the escrow with `PermitToken`, an EIP-2612 mock USDC,
 * so this runs against the real deployment. The escrow's permit call is best-effort
 * (`try/catch`) because the allowance may already exist, which means a broken signature
 * surfaces as a transfer failure rather than a permit failure — hence the allowance
 * assertions around it.
 */
import { createWalletClient, http, type Address, type PrivateKeyAccount } from 'viem';
import { foundry } from 'viem/chains';
import type { Addresses } from '../src/addresses.js';
import { parseUsdc } from '../src/amount.js';
import { createNexusClient } from '../src/client.js';
import { signPermit } from '../src/permit.js';
import type { Job, NexusPublicClient, NexusWalletClient } from '../src/types.js';

export interface PermitLegParams {
  publicClient: NexusPublicClient;
  /** Client principal that signs the permit and pays. Must hold the payment token. */
  principal: PrivateKeyAccount;
  provider: Address;
  addresses: Addresses;
  rpcUrl: string;
  /** Job deadline in unix seconds. */
  deadline: number;
}

export interface PermitLegResult {
  jobId: bigint;
  job: Job;
  total: bigint;
  /** Allowance before the permit — must be 0 for the leg to prove anything. */
  allowanceBefore: bigint;
  allowanceAfter: bigint;
  balanceSpent: bigint;
}

export async function runPermitLeg(params: PermitLegParams): Promise<PermitLegResult> {
  const { publicClient, principal, provider, addresses, rpcUrl, deadline } = params;

  const walletClient = createWalletClient({
    account: principal,
    chain: foundry,
    transport: http(rpcUrl),
  }) as NexusWalletClient;
  const client = createNexusClient({ publicClient, walletClient, addresses });

  const totalUsdc = '75.25';
  const total = parseUsdc(totalUsdc);
  const allowanceBefore = await client.usdc.allowance(principal.address, addresses.escrow);
  const balanceBefore = await client.usdc.balanceOf(principal.address);

  const block = await publicClient.getBlock();
  const permitDeadline = block.timestamp + 3600n;
  // No `version`: resolveEip712Version reads the token's ERC-5267 descriptor.
  const signed = await signPermit({
    walletClient,
    publicClient,
    token: addresses.paymentToken,
    owner: principal.address,
    spender: addresses.escrow,
    value: totalUsdc,
    deadline: permitDeadline,
  });

  const created = await client.escrow.createJobWithPermit(
    { client: principal.address, provider, milestoneAmounts: [totalUsdc], deadline },
    permitDeadline,
    signed,
  );

  const [job, allowanceAfter, balanceAfter] = await Promise.all([
    client.escrow.getJob(created.jobId),
    client.usdc.allowance(principal.address, addresses.escrow),
    client.usdc.balanceOf(principal.address),
  ]);
  return {
    jobId: created.jobId,
    job,
    total,
    allowanceBefore,
    allowanceAfter,
    balanceSpent: balanceBefore - balanceAfter,
  };
}
