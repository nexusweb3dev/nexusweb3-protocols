import { NexusError } from './types.js';

/**
 * Decimals of the payment token. USDC uses 6 on every Circle deployment, and the v2 contracts
 * assume it: reputation volume, kill-switch spending limits and escrow milestones are all
 * denominated in these units.
 */
export const USDC_DECIMALS = 6;

/**
 * An amount of the payment token.
 *
 * A **string** is a human USDC amount — `'100.50'` means one hundred dollars fifty. This is the
 * form every surface of the SDK accepts, and the only form the CLI and the MCP tools take.
 * A **bigint** is an escape hatch for callers that already hold base units, e.g. a value read
 * back off-chain: `100_500_000n` is the same amount. The type, not the digits, decides — there
 * is no value that could mean either.
 */
export type UsdcAmount = string | bigint;

const DECIMAL_PATTERN = /^(\d+)(?:\.(\d*))?$/;

/**
 * Parse a human USDC amount into base units. Rejects anything that is not a plain non-negative
 * decimal, and anything finer than {@link USDC_DECIMALS} places rather than silently truncating
 * a payment.
 */
export function parseUsdc(amount: string, label = 'amount'): bigint {
  const trimmed = amount.trim();
  const match = DECIMAL_PATTERN.exec(trimmed);
  if (!match) {
    throw new NexusError(
      `${label} must be a non-negative decimal USDC amount such as "100.50", got "${amount}"`,
    );
  }
  const whole = match[1] ?? '0';
  const fraction = match[2] ?? '';
  if (fraction.length > USDC_DECIMALS) {
    throw new NexusError(
      `${label} "${amount}" has ${fraction.length} decimal places; USDC holds at most ${USDC_DECIMALS}`,
    );
  }
  return BigInt(whole + fraction.padEnd(USDC_DECIMALS, '0'));
}

/** Normalize either form of {@link UsdcAmount} to base units. */
export function toBaseUnits(amount: UsdcAmount, label = 'amount'): bigint {
  if (typeof amount === 'bigint') {
    if (amount < 0n) throw new NexusError(`${label} must not be negative, got ${amount}`);
    return amount;
  }
  return parseUsdc(amount, label);
}

/** Render base units as a human USDC string, the inverse of {@link parseUsdc}. */
export function formatUsdc(amount: bigint): string {
  const negative = amount < 0n;
  const digits = (negative ? -amount : amount).toString().padStart(USDC_DECIMALS + 1, '0');
  const whole = digits.slice(0, -USDC_DECIMALS);
  const fraction = digits.slice(-USDC_DECIMALS).replace(/0+$/, '');
  return `${negative ? '-' : ''}${whole}${fraction ? `.${fraction}` : ''}`;
}
