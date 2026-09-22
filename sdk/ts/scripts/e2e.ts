/**
 * End-to-end check of the SDK against a local anvil with the v2 core deployed.
 *
 *   anvil --port 8545 --silent &
 *   PRIVATE_KEY=0xac09…ff80 DEPLOY_JSON_PATH=deployments/v2-local-ts.json \
 *     forge script script/v2/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *   npm run e2e
 *
 * Env: RPC_URL (default http://127.0.0.1:8545), ADDRESSES_JSON (default ../../deployments/v2-local-ts.json).
 */
import { readFileSync } from 'node:fs';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  http,
  keccak256,
  stringToHex,
  zeroAddress,
  type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { foundry } from 'viem/chains';
import { loadAddresses } from '../src/addresses.js';
import { formatUsdc, parseUsdc } from '../src/amount.js';
import { createNexusClient, type NexusClient } from '../src/client.js';
import { TIERS, type NexusPublicClient, type NexusWalletClient } from '../src/types.js';
import { runPermitLeg } from './permit-leg.js';
import { runCancelLeg, runSettleLeg } from './timeout-legs.js';

const here = dirname(fileURLToPath(import.meta.url));
const sdkRoot = resolve(here, '..');

const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
const addressesArg = process.env.ADDRESSES_JSON ?? '../../deployments/v2-local-ts.json';
const addressesPath = isAbsolute(addressesArg) ? addressesArg : resolve(sdkRoot, addressesArg);

/** AgentEscrowV2.REVIEW_WINDOW — a Submitted milestone the client ignores this long can be claimed. */
const REVIEW_WINDOW_SECONDS = 7 * 24 * 60 * 60;

const KEYS = {
  clientPrincipal: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  clientOperator: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  providerPrincipal: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
  providerOperator: '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
  permitPrincipal: '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a',
  /** anvil #5: settles an expired job as an unrelated third party. */
  bystander: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba',
} as const;

const results: Array<{ name: string; ok: boolean; detail: string }> = [];

function check(name: string, ok: boolean, detail: string): void {
  results.push({ name, ok, detail });
  process.stdout.write(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}\n`);
}

function step(message: string): void {
  process.stdout.write(`\n▸ ${message}\n`);
}

const publicClient = createPublicClient({ chain: foundry, transport: http(rpcUrl) }) as NexusPublicClient;
const accounts = {
  clientPrincipal: privateKeyToAccount(KEYS.clientPrincipal),
  clientOperator: privateKeyToAccount(KEYS.clientOperator),
  providerPrincipal: privateKeyToAccount(KEYS.providerPrincipal),
  providerOperator: privateKeyToAccount(KEYS.providerOperator),
  permitPrincipal: privateKeyToAccount(KEYS.permitPrincipal),
  bystander: privateKeyToAccount(KEYS.bystander),
};

const addresses = loadAddresses(JSON.parse(readFileSync(addressesPath, 'utf8')));

function wallet(account: (typeof accounts)[keyof typeof accounts]): NexusWalletClient {
  return createWalletClient({ account, chain: foundry, transport: http(rpcUrl) }) as NexusWalletClient;
}

function nexus(account: (typeof accounts)[keyof typeof accounts]): NexusClient {
  return createNexusClient({ publicClient, walletClient: wallet(account), addresses });
}

async function ensureIdentity(client: NexusClient, agent: Address, name: string): Promise<void> {
  if (await client.identity.isRegistered(agent)) return;
  await client.identity.register(agent, name, `https://agents.nexusweb3.dev/${name}.json`, 1);
}

async function main(): Promise<void> {
  process.stdout.write(`rpc=${rpcUrl}\naddresses=${addressesPath}\nescrow=${addresses.escrow}\n`);

  const clientPrincipal = nexus(accounts.clientPrincipal);
  const clientOperator = nexus(accounts.clientOperator);
  const providerPrincipal = nexus(accounts.providerPrincipal);
  const providerOperator = nexus(accounts.providerOperator);

  const clientAddress = accounts.clientPrincipal.address;
  const providerAddress = accounts.providerPrincipal.address;
  const suffix = Date.now().toString(36);

  step('principals authorize their hot operator keys');
  await clientPrincipal.access.authorizeOperator(accounts.clientOperator.address);
  await providerPrincipal.access.authorizeOperator(accounts.providerOperator.address);
  check(
    'operators authorized',
    (await clientPrincipal.access.isOperatorFor(clientAddress, accounts.clientOperator.address)) &&
      (await providerPrincipal.access.isOperatorFor(providerAddress, accounts.providerOperator.address)),
    'client + provider hot keys accepted',
  );

  step('principals approve USDC to the escrow');
  // Amounts go in as USDC figures; balances come back in base units, which is what the chain stores.
  const budget = '10000';
  await clientPrincipal.usdc.approve(addresses.escrow, budget);
  await providerPrincipal.usdc.approve(addresses.escrow, budget);
  check(
    'usdc approved',
    (await clientPrincipal.usdc.allowance(clientAddress, addresses.escrow)) >= parseUsdc(budget),
    `${budget} USDC`,
  );

  step('operators register the principals in AgentIdentityV2');
  await ensureIdentity(clientOperator, clientAddress, `e2e-client-${suffix}`);
  await ensureIdentity(providerOperator, providerAddress, `e2e-provider-${suffix}`);
  const providerProfile = await providerOperator.identity.getAgent(providerAddress);
  check(
    'identities registered by operators',
    providerProfile.active && providerProfile.name.startsWith('e2e-provider-'),
    `provider name=${providerProfile.name}`,
  );

  step('client operator renames the client identity, freeing the old handle');
  const oldName = (await clientOperator.identity.getAgent(clientAddress)).name;
  const newName = `${oldName}-renamed`;
  await clientOperator.identity.rename(clientAddress, newName);
  const renamed = await clientOperator.identity.getAgent(clientAddress);
  const freed = await clientOperator.identity.getAgentByName(oldName);
  check(
    'rename takes the new name and releases the old one',
    renamed.name === newName && freed === zeroAddress,
    `name=${renamed.name} oldNameOwner=${freed}`,
  );

  step('client operator creates a 2-milestone job ($100 + $150.50)');
  const milestones = ['100', '150.50'] as const;
  const total = parseUsdc(milestones[0]) + parseUsdc(milestones[1]);
  const block = await publicClient.getBlock();
  // Baselines, so the script is also correct against a chain that already has history.
  const providerBefore = await providerOperator.usdc.balanceOf(providerAddress);
  const statsBefore = await providerOperator.reputation.getStats(providerAddress);
  const logCountBefore = await providerOperator.auditLog.getLogCount(providerAddress);
  const created = await clientOperator.escrow.createJob({
    client: clientAddress,
    provider: providerAddress,
    milestoneAmounts: milestones,
    deadline: Number(block.timestamp) + 7 * 24 * 60 * 60,
    termsHash: keccak256(stringToHex(`e2e terms ${suffix}`)),
  });
  check('job created', created.jobId >= 0n, `jobId=${created.jobId} tx=${created.hash}`);

  step('provider operator accepts the offer, binding the provider to it');
  const beforeAccept = await clientOperator.escrow.getJob(created.jobId);
  await providerOperator.escrow.acceptJob(created.jobId);
  const accepted = await clientOperator.escrow.getJob(created.jobId);
  check(
    'acceptJob records acceptedAt',
    beforeAccept.acceptedAt === 0 && accepted.acceptedAt > 0,
    `before=${beforeAccept.acceptedAt} after=${accepted.acceptedAt}`,
  );

  step('provider submits and client approves both milestones');
  for (const index of [0, 1] as const) {
    await providerOperator.escrow.submitMilestone(
      created.jobId,
      index,
      keccak256(stringToHex(`deliverable-${index}-${suffix}`)),
    );
    const submitted = await providerOperator.escrow.getMilestones(created.jobId);
    check(`milestone ${index} submitted`, submitted[index]?.status === 'Submitted', `status=${submitted[index]?.status}`);
    const release = await clientOperator.escrow.approveMilestone(created.jobId, index);
    const approved = await clientOperator.escrow.getMilestones(created.jobId);
    check(`milestone ${index} approved`, approved[index]?.status === 'Approved', `status=${approved[index]?.status}`);
    // PayoutSettled proves the money actually reached the provider rather than landing in
    // `claimable`, which a successful receipt alone cannot tell you.
    const payout = release.payouts[0];
    check(
      `milestone ${index} payout delivered to the provider`,
      release.payouts.length === 1 &&
        payout !== undefined &&
        payout.delivered === true &&
        payout.account === providerAddress,
      `payouts=${release.payouts
        .map((entry) => `${entry.account}:${formatUsdc(entry.amount)}:${entry.delivered}`)
        .join(' ')}`,
    );
  }

  step('assert settlement, reputation and audit log');
  const job = await clientOperator.escrow.getJob(created.jobId);
  check('job status Completed', job.status === 'Completed', `status=${job.status} released=${job.released}`);

  const providerAfter = await providerOperator.usdc.balanceOf(providerAddress);
  check(
    'provider paid 250.50 USDC',
    providerAfter - providerBefore === total,
    `delta=${formatUsdc(providerAfter - providerBefore)} expected=${formatUsdc(total)}`,
  );

  const stats = await providerOperator.reputation.getStats(providerAddress);
  const positives = stats.positives - statsBefore.positives;
  check(
    'provider reputation positives == 2',
    positives === 2n && stats.negatives === statsBefore.negatives,
    `positives=+${positives} negatives=+${stats.negatives - statsBefore.negatives}`,
  );

  const tier = await providerOperator.reputation.getTier(providerAddress);
  check('getTier returns a string union', TIERS.includes(tier), `tier=${tier}`);

  const logCount = await providerOperator.auditLog.getLogCount(providerAddress);
  const logs = await providerOperator.auditLog.getAgentLogs(providerAddress, logCountBefore, 20n);
  check('audit log count >= 4', logCount - logCountBefore >= 4n, `entries this run=${logCount - logCountBefore}`);
  check(
    'audit action types decode to strings',
    logs.some((entry) => entry.actionType === 'ESCROW_JOB_CREATED') &&
      logs.some((entry) => entry.actionType === 'ESCROW_MILESTONE_APPROVED'),
    logs.map((entry) => entry.actionType).join(','),
  );
  // Best-effort (try/catch) hooks only run when the tx carries more gas than eth_estimateGas
  // returns; this asserts the SDK's gas buffer actually keeps them alive.
  check(
    'best-effort submit logs survived gas estimation',
    logs.filter((entry) => entry.actionType === 'ESCROW_MILESTONE_SUBMITTED').length === 2,
    `submitted entries=${logs.filter((entry) => entry.actionType === 'ESCROW_MILESTONE_SUBMITTED').length}`,
  );

  const jobIds = await clientOperator.escrow.getJobsOf(clientAddress, 0n, 50n);
  check('job listed for the client principal', jobIds.includes(created.jobId), `ids=[${jobIds.join(',')}]`);

  step('signPermit + createJobWithPermit with no prior approve (anvil #4)');
  const permitDeadline = Number(block.timestamp) + 30 * 24 * 60 * 60;
  const permit = await runPermitLeg({
    publicClient,
    principal: accounts.permitPrincipal,
    provider: providerAddress,
    addresses,
    rpcUrl,
    deadline: permitDeadline,
  });
  check(
    'permit job created without a prior approve',
    permit.allowanceBefore === 0n && permit.balanceSpent === permit.total,
    `allowanceBefore=${permit.allowanceBefore} spent=${permit.balanceSpent}`,
  );
  check(
    'permit job exists and is funded',
    permit.job.status === 'Open' && permit.job.total === permit.total,
    `jobId=${permit.jobId} status=${permit.job.status} total=${permit.job.total}`,
  );

  step('provider claims a milestone the client ignored for 8 days');
  const permitProvider = providerOperator;
  await permitProvider.escrow.acceptJob(permit.jobId);
  const tokensBefore = await permitProvider.usdc.balanceOf(providerAddress);
  await permitProvider.escrow.submitMilestone(
    permit.jobId,
    0,
    keccak256(stringToHex(`permit-deliverable-${suffix}`)),
  );
  const [submitted] = await permitProvider.escrow.getMilestones(permit.jobId);
  const expiry = await permitProvider.escrow.expiryOf(permit.jobId);
  check(
    'expiryOf is max(deadline, submittedAt + review window)',
    submitted !== undefined &&
      expiry === Math.max(permitDeadline, submitted.submittedAt + REVIEW_WINDOW_SECONDS),
    `expiry=${expiry} deadline=${permitDeadline} submittedAt=${submitted?.submittedAt ?? 0}`,
  );

  const testClient = createTestClient({ chain: foundry, mode: 'anvil', transport: http(rpcUrl) });
  await testClient.increaseTime({ seconds: 8 * 24 * 60 * 60 });
  await testClient.mine({ blocks: 1 });

  await permitProvider.escrow.claimApproval(permit.jobId, 0);
  const claimed = await permitProvider.escrow.getJob(permit.jobId);
  const tokensAfter = await permitProvider.usdc.balanceOf(providerAddress);
  check(
    'claimApproval paid the provider',
    tokensAfter - tokensBefore === permit.total,
    `delta=${tokensAfter - tokensBefore} expected=${permit.total}`,
  );
  check('claimed job is Completed', claimed.status === 'Completed', `status=${claimed.status}`);

  const timeoutLegs = {
    publicClient,
    clientOperator,
    providerOperator,
    bystander: nexus(accounts.bystander),
    clientAddress,
    providerAddress,
    testClient,
    check,
    suffix,
  };

  step('client goes silent after a submission: a bystander settles the expired job');
  await runSettleLeg(timeoutLegs);

  step('client cancels an offer the provider never accepted: full refund');
  await runCancelLeg(timeoutLegs);
}

main()
  .then(() => {
    const failed = results.filter((result) => !result.ok);
    process.stdout.write(`\n${'─'.repeat(64)}\n`);
    process.stdout.write(`E2E ${failed.length === 0 ? 'PASS' : 'FAIL'}: ${results.length - failed.length}/${results.length} checks passed\n`);
    for (const failure of failed) process.stdout.write(`  FAILED: ${failure.name} — ${failure.detail}\n`);
    process.exit(failed.length === 0 ? 0 : 1);
  })
  .catch((error: unknown) => {
    process.stdout.write(`\n${'─'.repeat(64)}\nE2E FAIL: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
    process.exit(1);
  });
