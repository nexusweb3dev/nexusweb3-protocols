import {
  createPublicClient,
  custom,
  parseSignature,
  type Address,
  type Hex,
  type TypedDataDomain,
} from 'viem';
import { erc20Abi } from './abis/erc20.js';
import { NexusError, type NexusPublicClient, type NexusWalletClient, type PermitSignature } from './types.js';

/** EIP-2612 `Permit` type, identical for every compliant token. */
export const PERMIT_TYPES = {
  Permit: [
    { name: 'owner', type: 'address' },
    { name: 'spender', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

/** USDC (Base and every Circle deployment) signs its permits with EIP-712 version "2". */
export const USDC_EIP712_VERSION = '2';

export interface PermitMessage {
  owner: Address;
  spender: Address;
  value: bigint;
  nonce: bigint;
  deadline: bigint;
}

export interface PermitTypedData {
  domain: TypedDataDomain;
  types: typeof PERMIT_TYPES;
  primaryType: 'Permit';
  message: PermitMessage;
}

export interface BuildPermitTypedDataParams extends PermitMessage {
  name: string;
  version: string;
  chainId: number;
  verifyingContract: Address;
}

/** Pure EIP-712 payload builder — no chain access, so it is directly unit testable. */
export function buildPermitTypedData(params: BuildPermitTypedDataParams): PermitTypedData {
  const { name, version, chainId, verifyingContract, owner, spender, value, nonce, deadline } = params;
  return {
    domain: { name, version, chainId, verifyingContract },
    types: PERMIT_TYPES,
    primaryType: 'Permit',
    message: { owner, spender, value, nonce, deadline },
  };
}

export interface SignPermitParams {
  walletClient: NexusWalletClient;
  token: Address;
  owner: Address;
  spender: Address;
  value: bigint;
  /** Unix seconds. */
  deadline: bigint;
  /** Public client for the `name()` / `nonces()` reads. Derived from the wallet transport when omitted. */
  publicClient?: NexusPublicClient;
  /** EIP-712 domain version. Defaults to "2" (USDC); OpenZeppelin ERC20Permit tokens use "1". */
  version?: string;
}

export interface SignedPermit extends PermitSignature {
  signature: Hex;
  deadline: bigint;
  nonce: bigint;
  typedData: PermitTypedData;
}

function publicClientFrom(walletClient: NexusWalletClient): NexusPublicClient {
  return createPublicClient({
    chain: walletClient.chain,
    transport: custom({ request: walletClient.request }),
  }) as NexusPublicClient;
}

/**
 * Sign an EIP-2612 permit for `value` of `token`, ready for
 * `escrow.createJobWithPermit`. Reads `name()`/`nonces()` from the token and the
 * chain id from the client; the domain version falls back to the token's own
 * ERC-5267 `eip712Domain()` when it exposes one.
 */
export async function signPermit(params: SignPermitParams): Promise<SignedPermit> {
  const { walletClient, token, owner, spender, value, deadline } = params;
  const publicClient = params.publicClient ?? publicClientFrom(walletClient);
  const chainId = walletClient.chain?.id ?? (await publicClient.getChainId());

  const [name, nonce] = await Promise.all([
    publicClient.readContract({ address: token, abi: erc20Abi, functionName: 'name' }),
    publicClient.readContract({ address: token, abi: erc20Abi, functionName: 'nonces', args: [owner] }),
  ]);

  let version = params.version;
  if (version === undefined) {
    try {
      const domain = await publicClient.readContract({
        address: token,
        abi: erc20Abi,
        functionName: 'eip712Domain',
      });
      version = domain[2];
    } catch {
      version = USDC_EIP712_VERSION;
    }
  }

  const typedData = buildPermitTypedData({
    name,
    version,
    chainId,
    verifyingContract: token,
    owner,
    spender,
    value,
    nonce,
    deadline,
  });

  let signature: Hex;
  try {
    signature = await walletClient.signTypedData({
      account: walletClient.account,
      domain: typedData.domain,
      types: typedData.types,
      primaryType: typedData.primaryType,
      message: typedData.message,
    });
  } catch (error) {
    throw new NexusError(`Failed to sign permit for token ${token}`, error);
  }

  const { v, r, s } = parseSignature(signature);
  if (v === undefined) {
    throw new NexusError('Permit signature is missing its v parameter');
  }
  return { v: Number(v), r, s, signature, deadline, nonce, typedData };
}
