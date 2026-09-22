import { describe, expect, it } from 'vitest';
import { z } from 'zod';
import { AgentEscrowV2Abi } from '../src/abis/AgentEscrowV2.js';
import { AgentIdentityV2Abi } from '../src/abis/AgentIdentityV2.js';
import { FeeRouterAbi } from '../src/abis/FeeRouter.js';

const names = (kind: string): string[] =>
  AgentEscrowV2Abi.filter((entry) => entry.type === kind).map((entry) => (entry as { name: string }).name);

describe('AgentEscrowV2 ABI surface', () => {
  it('carries the post-audit lifecycle functions', () => {
    expect(names('function')).toEqual(
      expect.arrayContaining([
        'acceptJob',
        'settleExpired',
        'withdrawClaimable',
        'claimApproval',
        'MAX_REJECTIONS',
        'MAX_REPUTATION_PER_PAIR',
        'DISPUTE_GRACE',
      ]),
    );
  });

  it('no longer exposes the refund-only settlement path', () => {
    expect(names('function')).not.toContain('refundExpired');
  });

  it('takes an account and a recipient on withdrawClaimable', () => {
    const entry = AgentEscrowV2Abi.find(
      (item) => item.type === 'function' && item.name === 'withdrawClaimable',
    );
    expect(entry && 'inputs' in entry ? entry.inputs.map((input) => input.name) : []).toEqual([
      'account',
      'to',
    ]);
  });

  it('declares the new events and errors the SDK decodes', () => {
    expect(names('event')).toEqual(
      expect.arrayContaining(['JobAccepted', 'JobExpired', 'ClaimableWithdrawn', 'PayoutSettled']),
    );
    expect(names('error')).toEqual(
      expect.arrayContaining([
        'NotAccepted',
        'AlreadyAccepted',
        'ReviewWindowClosed',
        'TooManyRejections',
        'TokenAmountMismatch',
      ]),
    );
  });

  it('PayoutSettled carries the fields the SDK reads back as `payouts`', () => {
    const entry = AgentEscrowV2Abi.find(
      (item) => item.type === 'event' && item.name === 'PayoutSettled',
    );
    const inputs = entry && 'inputs' in entry ? entry.inputs : [];
    expect(inputs.map((input) => input.name)).toEqual(['jobId', 'account', 'amount', 'delivered']);
    expect(inputs.map((input) => input.type)).toEqual(['uint256', 'address', 'uint256', 'bool']);
  });

  it('exposes the new Job and Milestone fields through getJob / getMilestones', () => {
    const outputs = (fn: string): string[] => {
      const entry = AgentEscrowV2Abi.find((item) => item.type === 'function' && item.name === fn);
      const first = entry && 'outputs' in entry ? entry.outputs[0] : undefined;
      return first && 'components' in first && first.components
        ? first.components.map((component) => component.name)
        : [];
    };
    expect(outputs('getJob')).toEqual(expect.arrayContaining(['acceptedAt', 'disputedAt', 'everSubmitted']));
    expect(outputs('getMilestones')).toContain('rejections');
  });
});

describe('sibling module ABIs', () => {
  it('AgentIdentityV2 exposes registryEpoch and the zero-id guard', () => {
    const functions = AgentIdentityV2Abi.filter((entry) => entry.type === 'function').map(
      (entry) => (entry as { name: string }).name,
    );
    const errors = AgentIdentityV2Abi.filter((entry) => entry.type === 'error').map(
      (entry) => (entry as { name: string }).name,
    );
    expect(functions).toContain('registryEpoch');
    expect(errors).toContain('InvalidERC8004Id');
  });

  it('AgentIdentityV2 exposes rename and the event that pairs with it', () => {
    const entry = AgentIdentityV2Abi.find((item) => item.type === 'function' && item.name === 'rename');
    expect(entry && 'inputs' in entry ? entry.inputs.map((input) => input.name) : []).toEqual([
      'agent',
      'newName',
    ]);
    const events = AgentIdentityV2Abi.filter((item) => item.type === 'event').map(
      (item) => (item as { name: string }).name,
    );
    expect(events).toContain('AgentRenamed');
  });

  it('FeeRouter reports a failed referral payout instead of reverting', () => {
    const events = FeeRouterAbi.filter((entry) => entry.type === 'event').map(
      (entry) => (entry as { name: string }).name,
    );
    expect(events).toContain('ReferralCallFailed');
  });
});


describe('MCP amount schema', () => {
  // Mirrors `usdcArg` in src/mcp/tools/write.ts: the boundary that stops a base-unit figure.
  const usdcArg = z.string().regex(/^\d+(\.\d{1,6})?$/);

  it('accepts dollars and cents', () => {
    for (const value of ['100', '100.5', '100.50', '0', '0.000001', '250000']) {
      expect(usdcArg.safeParse(value).success).toBe(true);
    }
  });

  it('rejects the forms a model reaches for when it thinks in base units', () => {
    for (const value of ['1.0000001', '1e6', '-1', '100 USDC', '0x64', '', '1,000']) {
      expect(usdcArg.safeParse(value).success).toBe(false);
    }
  });
});
