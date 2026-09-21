import { describe, expect, it } from 'vitest';
import { size, stringToHex } from 'viem';
import { NO_EXPIRY } from '../src/modules/access.js';
import {
  decodeActionType,
  decodeJobStatus,
  decodeMilestoneStatus,
  decodeTier,
  encodeActionType,
  JOB_STATUSES,
  MILESTONE_STATUSES,
  NexusError,
  TIERS,
} from '../src/types.js';

describe('bytes32 action types', () => {
  const labels = ['ESCROW_JOB_CREATED', 'TRADE_EXECUTED', 'a', 'x'.repeat(32)];

  it.each(labels)('round-trips %s', (label) => {
    const encoded = encodeActionType(label);
    expect(size(encoded)).toBe(32);
    expect(decodeActionType(encoded)).toBe(label);
  });

  it('right-pads with zeros exactly like Solidity string literals', () => {
    expect(encodeActionType('ESCROW_JOB_CREATED')).toBe(stringToHex('ESCROW_JOB_CREATED', { size: 32 }));
    expect(encodeActionType('A')).toBe(`0x41${'00'.repeat(31)}`);
  });

  it('refuses a label longer than 32 bytes', () => {
    expect(() => encodeActionType('y'.repeat(33))).toThrowError();
  });
});

describe('enum decoders', () => {
  it('decodes every tier', () => {
    expect(TIERS.map((_, index) => decodeTier(index))).toEqual(['BRONZE', 'SILVER', 'GOLD', 'PLATINUM']);
  });

  it('decodes every job status', () => {
    expect(JOB_STATUSES.map((_, index) => decodeJobStatus(index))).toEqual([
      'Open',
      'Completed',
      'Cancelled',
      'Disputed',
      'Resolved',
      'Expired',
    ]);
  });

  it('decodes every milestone status', () => {
    expect(MILESTONE_STATUSES.map((_, index) => decodeMilestoneStatus(index))).toEqual([
      'Pending',
      'Submitted',
      'Approved',
    ]);
  });

  it('throws on an out-of-range value', () => {
    expect(() => decodeTier(4)).toThrowError(NexusError);
    expect(() => decodeJobStatus(6)).toThrowError(/JobStatus/);
    expect(() => decodeMilestoneStatus(-1)).toThrowError(/MilestoneStatus/);
  });
});

describe('NO_EXPIRY', () => {
  it('is uint48 max', () => {
    expect(NO_EXPIRY).toBe(2 ** 48 - 1);
  });
});
