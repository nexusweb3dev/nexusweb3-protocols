import { getContract, type Address } from 'viem';
import { erc20Abi } from '../abis/erc20.js';
import { sendWrite, type Context } from '../internal.js';
import type { TxResult } from '../types.js';

/** Minimal ERC-20 surface for the configured payment token (USDC on Base). */
export interface UsdcModule {
  readonly address: Address;
  approve(spender: Address, amount: bigint): Promise<TxResult>;
  transfer(to: Address, amount: bigint): Promise<TxResult>;
  balanceOf(account: Address): Promise<bigint>;
  allowance(owner: Address, spender: Address): Promise<bigint>;
  decimals(): Promise<number>;
}

export function createUsdcModule(ctx: Context): UsdcModule {
  const address = ctx.addresses.paymentToken;
  const reader = getContract({ address, abi: erc20Abi, client: ctx.publicClient });

  return {
    address,
    async approve(spender, amount) {
      return sendWrite(ctx, address, erc20Abi, 'approve', [spender, amount]);
    },
    async transfer(to, amount) {
      return sendWrite(ctx, address, erc20Abi, 'transfer', [to, amount]);
    },
    balanceOf: (account) => reader.read.balanceOf([account]),
    allowance: (owner, spender) => reader.read.allowance([owner, spender]),
    decimals: () => reader.read.decimals(),
  };
}
