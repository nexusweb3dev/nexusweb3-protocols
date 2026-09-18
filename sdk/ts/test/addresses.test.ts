import { describe, expect, it } from 'vitest';
import { BASE_ERC8004_IDENTITY_REGISTRY, loadAddresses, readChainId } from '../src/addresses.js';
import { NexusError } from '../src/types.js';

const DEPLOYMENT = {
  AgentAccess: '0x0165878a594ca255338adfa4d48449f69242eb8f',
  AgentAuditLogV2: '0x610178da211fef7d417bc0e6fed39f05609ad788',
  AgentEscrowV2: '0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0',
  AgentIdentityV2: '0xa513e6e4b8f2a923d98304ec87f64353c4d5c853',
  AgentKillSwitchV2: '0x8a791620dd6260079bf849dc5567adc3f2fdc318',
  AgentReputationV2: '0x2279b7a0a67db372996a5fab50d91eaa73d2ebe6',
  FeeRouter: '0xb7f8bc63bbcad18155201308c8f3540b07f84f5e',
  chainId: 31337,
  owner: '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266',
  paymentToken: '0x5fbdb2315678afecb367f032d93f642f64180aa3',
  treasury: '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266',
};

describe('loadAddresses', () => {
  it('maps every deployment key onto the Addresses shape', () => {
    const addresses = loadAddresses(DEPLOYMENT);
    expect(Object.keys(addresses).sort()).toEqual([
      'access',
      'auditLog',
      'escrow',
      'feeRouter',
      'identity',
      'killSwitch',
      'paymentToken',
      'reputation',
    ]);
    expect(addresses.escrow).toBe('0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0');
    expect(addresses.paymentToken).toBe('0x5FbDB2315678afecb367f032d93F642f64180aa3');
  });

  it('checksums lower-case input', () => {
    expect(loadAddresses(DEPLOYMENT).access).toBe('0x0165878A594ca255338adfa4d48449f69242Eb8F');
  });

  it('rejects a missing contract', () => {
    const { AgentEscrowV2: _omitted, ...rest } = DEPLOYMENT;
    expect(() => loadAddresses(rest)).toThrowError(NexusError);
    expect(() => loadAddresses(rest)).toThrowError(/AgentEscrowV2/);
  });

  it('rejects a malformed address', () => {
    expect(() => loadAddresses({ ...DEPLOYMENT, FeeRouter: '0xdeadbeef' })).toThrowError(/FeeRouter/);
  });

  it('rejects non-objects', () => {
    expect(() => loadAddresses(null)).toThrowError(NexusError);
    expect(() => loadAddresses('deployments/v2-8453.json')).toThrowError(NexusError);
  });
});

describe('readChainId', () => {
  it('reads the chain id when present', () => {
    expect(readChainId(DEPLOYMENT)).toBe(31337);
  });

  it('returns undefined when absent', () => {
    expect(readChainId({})).toBeUndefined();
    expect(readChainId(undefined)).toBeUndefined();
  });
});

describe('BASE_ERC8004_IDENTITY_REGISTRY', () => {
  it('is the canonical Base registry', () => {
    expect(BASE_ERC8004_IDENTITY_REGISTRY).toBe('0x8004A169FB4a3325136EB29fA0ceB6D2e539a432');
  });
});
