import { describe, expect, it } from 'vitest';
import { formatUsdc, parseUsdc, toBaseUnits, USDC_DECIMALS } from '../src/amount.js';
import {
  DEFAULT_EIP712_VERSION,
  KNOWN_EIP712_VERSIONS,
  resolveEip712Version,
  USDC_EIP712_VERSION,
} from '../src/permit.js';
import { NexusError, type NexusPublicClient } from '../src/types.js';

const BASE_USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const BASE_SEPOLIA_USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e';

describe('parseUsdc', () => {
  it('reads dollars, not base units', () => {
    expect(USDC_DECIMALS).toBe(6);
    expect(parseUsdc('100')).toBe(100_000_000n);
    expect(parseUsdc('100.50')).toBe(100_500_000n);
    expect(parseUsdc('0.000001')).toBe(1n);
    expect(parseUsdc('0')).toBe(0n);
    expect(parseUsdc(' 250.5 ')).toBe(250_500_000n);
  });

  it('refuses precision it would have to throw away', () => {
    expect(() => parseUsdc('1.0000001')).toThrowError(/at most 6/);
  });

  it('refuses anything that is not a plain decimal', () => {
    for (const bad of ['', '-1', '1e6', '1.2.3', '100 USDC', '0x64', 'NaN']) {
      expect(() => parseUsdc(bad)).toThrowError(NexusError);
    }
  });

  it('names the offending field', () => {
    expect(() => parseUsdc('nope', 'milestoneAmounts[1]')).toThrowError(/milestoneAmounts\[1\]/);
  });
});

describe('toBaseUnits', () => {
  it('treats a string as dollars and a bigint as base units', () => {
    expect(toBaseUnits('100')).toBe(100_000_000n);
    expect(toBaseUnits(100n)).toBe(100n);
    expect(toBaseUnits(100_000_000n)).toBe(100_000_000n);
  });

  it('rejects a negative amount', () => {
    expect(() => toBaseUnits(-1n)).toThrowError(NexusError);
  });
});

describe('formatUsdc', () => {
  it('round-trips through parseUsdc', () => {
    for (const value of ['0', '1', '100.5', '0.000001', '123456.789012']) {
      expect(formatUsdc(parseUsdc(value))).toBe(value);
    }
  });

  it('drops trailing zeros and keeps the dollar part', () => {
    expect(formatUsdc(250_000_000n)).toBe('250');
    expect(formatUsdc(1n)).toBe('0.000001');
    expect(formatUsdc(0n)).toBe('0');
  });
});

describe('resolveEip712Version', () => {
  const clientReturning = (version: string | null): NexusPublicClient =>
    ({
      readContract: async () => {
        if (version === null) throw new Error('execution reverted');
        return ['0x0f', 'USD Coin', version, 8453n, BASE_USDC, `0x${'00'.repeat(32)}`, []];
      },
    }) as unknown as NexusPublicClient;

  it('prefers the token ERC-5267 descriptor over the address table', async () => {
    // Even for a known address: on-chain truth wins over our copy of it.
    await expect(resolveEip712Version(clientReturning('7'), BASE_USDC)).resolves.toBe('7');
  });

  it('falls back to the known-address table when the token has no descriptor', async () => {
    const noDescriptor = clientReturning(null);
    await expect(resolveEip712Version(noDescriptor, BASE_USDC)).resolves.toBe(USDC_EIP712_VERSION);
    await expect(resolveEip712Version(noDescriptor, BASE_SEPOLIA_USDC)).resolves.toBe(
      USDC_EIP712_VERSION,
    );
  });

  it('falls back to "1" for an unknown token with no descriptor', async () => {
    const unknown = '0x000000000000000000000000000000000000dEaD';
    await expect(resolveEip712Version(clientReturning(null), unknown)).resolves.toBe(
      DEFAULT_EIP712_VERSION,
    );
    expect(DEFAULT_EIP712_VERSION).toBe('1');
  });

  it('ignores an empty version string', async () => {
    await expect(resolveEip712Version(clientReturning(''), BASE_USDC)).resolves.toBe(
      USDC_EIP712_VERSION,
    );
  });

  it('pins both Circle deployments to version 2', () => {
    expect(KNOWN_EIP712_VERSIONS[BASE_USDC]).toBe('2');
    expect(KNOWN_EIP712_VERSIONS[BASE_SEPOLIA_USDC]).toBe('2');
  });
});
