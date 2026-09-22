import type {
  Abi,
  Address,
  ContractEventName,
  ContractFunctionArgs,
  ContractFunctionName,
  Hash,
} from 'viem';
import { parseEventLogs } from 'viem';
import type { Addresses } from './addresses.js';
import {
  NexusError,
  type NexusPublicClient,
  type NexusWalletClient,
  type TxResult,
} from './types.js';

/**
 * Multiplier applied to the gas estimate of every write.
 *
 * AgentEscrowV2 writes reputation and the audit log through `try/catch` hooks, so a
 * transaction still succeeds when those inner calls run out of gas — which means
 * `eth_estimateGas` happily returns a limit that silently skips them (measured on
 * `submitMilestone`: 211k estimated vs 248k needed to actually write the log).
 * Unused gas is refunded, so the buffer only raises the required balance.
 */
export const DEFAULT_GAS_MULTIPLIER = 1.5;

/** Upper bound on {@link NexusClientConfig.gasMultiplier}, so a bad config cannot ask for an absurd gas limit. */
export const MAX_GAS_MULTIPLIER = 5;

export interface NexusClientConfig {
  publicClient: NexusPublicClient;
  /** Required for every write; omit for a read-only client. */
  walletClient?: NexusWalletClient;
  addresses: Addresses;
  /** Gas-estimate multiplier for writes. Default {@link DEFAULT_GAS_MULTIPLIER}; 1..{@link MAX_GAS_MULTIPLIER}. */
  gasMultiplier?: number;
}

/** Shared plumbing handed to each namespace module. */
export interface Context {
  readonly publicClient: NexusPublicClient;
  readonly walletClient: NexusWalletClient | undefined;
  readonly addresses: Addresses;
  readonly gasMultiplier: number;
  /** The wallet client, or a {@link NexusError} explaining that a signer is required. */
  requireWallet(): NexusWalletClient;
  /** Wait for the receipt and reject reverted transactions. */
  confirm(hash: Hash): Promise<TxResult>;
}

export function createContext(config: NexusClientConfig): Context {
  const { publicClient, walletClient, addresses } = config;
  const gasMultiplier = config.gasMultiplier ?? DEFAULT_GAS_MULTIPLIER;
  if (!Number.isFinite(gasMultiplier) || gasMultiplier < 1 || gasMultiplier > MAX_GAS_MULTIPLIER) {
    throw new NexusError(
      `gasMultiplier must be a finite number between 1 and ${MAX_GAS_MULTIPLIER}, got ${String(config.gasMultiplier)}`,
    );
  }

  return {
    publicClient,
    walletClient,
    addresses,
    gasMultiplier,
    requireWallet() {
      if (!walletClient) {
        throw new NexusError('This call needs a walletClient; the client was created read-only.');
      }
      return walletClient;
    },
    async confirm(hash: Hash): Promise<TxResult> {
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== 'success') {
        throw new NexusError(`Transaction ${hash} reverted`);
      }
      return { hash, receipt };
    },
  };
}

type WritableFunction<abi extends Abi> = ContractFunctionName<abi, 'nonpayable' | 'payable'>;

/**
 * Send one contract write with a buffered gas limit, then wait for the receipt.
 * Argument types come from the const ABI, so call sites stay fully checked.
 */
export async function sendWrite<const abi extends Abi, fn extends WritableFunction<abi>>(
  ctx: Context,
  address: Address,
  abi: abi,
  functionName: fn,
  args: ContractFunctionArgs<abi, 'nonpayable' | 'payable', fn>,
): Promise<TxResult> {
  const wallet = ctx.requireWallet();
  // One deliberate widening: the helper is generic, viem's overloads are not.
  const request = {
    address,
    abi: abi as Abi,
    functionName: functionName as string,
    args: args as readonly unknown[],
    account: wallet.account,
  };
  const estimate = await ctx.publicClient.estimateContractGas(request);
  const gas = (estimate * BigInt(Math.round(ctx.gasMultiplier * 100))) / 100n;
  const hash = await wallet.writeContract({ ...request, chain: wallet.chain ?? null, gas });
  return ctx.confirm(hash);
}

/**
 * Decode the single event named `eventName` emitted by `address` in a receipt.
 * Throws when the event is absent, which always means the ABI and the deployed
 * contract have drifted apart.
 */
export function requireEvent<const abi extends Abi, eventName extends ContractEventName<abi>>(
  abi: abi,
  eventName: eventName,
  address: Address,
  logs: TxResult['receipt']['logs'],
): { args: Record<string, unknown> } {
  const parsed = parseEventLogs({ abi, eventName, logs });
  const wanted = address.toLowerCase();
  const match = parsed.find((entry) => entry.address.toLowerCase() === wanted);
  if (!match) {
    throw new NexusError(`Event ${String(eventName)} not found in receipt logs of ${address}`);
  }
  return match as unknown as { args: Record<string, unknown> };
}

/** Read a required bigint field off a decoded event. */
export function eventBigInt(args: Record<string, unknown>, key: string): bigint {
  const value = args[key];
  if (typeof value !== 'bigint') {
    throw new NexusError(`Event field "${key}" is not a uint256`);
  }
  return value;
}
