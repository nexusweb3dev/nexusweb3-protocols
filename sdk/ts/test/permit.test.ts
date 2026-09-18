import { describe, expect, it } from 'vitest';
import { hashTypedData, recoverTypedDataAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { buildPermitTypedData, PERMIT_TYPES, USDC_EIP712_VERSION } from '../src/permit.js';

const ACCOUNT = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
const SPENDER = '0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0';
const TOKEN = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';

const params = {
  name: 'USD Coin',
  version: USDC_EIP712_VERSION,
  chainId: 8453,
  verifyingContract: TOKEN,
  owner: ACCOUNT.address,
  spender: SPENDER,
  value: 250_000_000n,
  nonce: 3n,
  deadline: 1_900_000_000n,
} as const;

describe('buildPermitTypedData', () => {
  it('produces the EIP-2612 domain, types and message', () => {
    const typedData = buildPermitTypedData(params);
    expect(typedData.primaryType).toBe('Permit');
    expect(typedData.types).toBe(PERMIT_TYPES);
    expect(typedData.types.Permit.map((field) => field.name)).toEqual([
      'owner',
      'spender',
      'value',
      'nonce',
      'deadline',
    ]);
    expect(typedData.domain).toEqual({
      name: 'USD Coin',
      version: '2',
      chainId: 8453,
      verifyingContract: TOKEN,
    });
    expect(typedData.message).toEqual({
      owner: ACCOUNT.address,
      spender: SPENDER,
      value: 250_000_000n,
      nonce: 3n,
      deadline: 1_900_000_000n,
    });
  });

  it('defaults USDC to EIP-712 version 2', () => {
    expect(USDC_EIP712_VERSION).toBe('2');
  });

  it('changes the digest when any field changes', () => {
    const base = hashTypedData(buildPermitTypedData(params));
    const other = hashTypedData(buildPermitTypedData({ ...params, value: 250_000_001n }));
    expect(base).not.toBe(other);
  });

  it('signs to a signature that recovers the owner', async () => {
    const typedData = buildPermitTypedData(params);
    const signature = await ACCOUNT.signTypedData(typedData);
    const recovered = await recoverTypedDataAddress({ ...typedData, signature });
    expect(recovered).toBe(ACCOUNT.address);
  });
});
