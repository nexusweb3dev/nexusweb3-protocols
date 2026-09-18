"""Transaction building: gas estimation, EIP-1559 fees, signing, receipt waiting."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Optional

from eth_account.signers.local import LocalAccount
from web3 import Web3
from web3.contract.contract import ContractFunction
from web3.exceptions import Web3Exception

from .errors import MissingSignerError, TransactionFailed

logger = logging.getLogger("nexusweb3")

#: Headroom over `eth_estimateGas`. The v2 contracts call the audit log, reputation and fee router
#: inside `try/catch`, so `eth_estimateGas` converges on a gas limit at which those inner calls run
#: out of gas and are swallowed: the transaction still succeeds but writes nothing. Measured worst
#: case on `submitMilestone` is 1.26x the estimate, so both a ratio and an absolute floor apply.
GAS_BUFFER_NUMERATOR = 3
GAS_BUFFER_DENOMINATOR = 2
GAS_BUFFER_MINIMUM = 75_000
#: Floor for the priority fee when the chain reports an empty `eth_feeHistory` reward set.
MIN_PRIORITY_FEE_WEI = 1_000_000_000

__all__ = ["TxResult", "TxSender", "GAS_BUFFER_NUMERATOR", "GAS_BUFFER_DENOMINATOR", "GAS_BUFFER_MINIMUM"]


@dataclass(frozen=True)
class TxResult:
    """Outcome of a successful write."""

    hash: str
    receipt: Any = field(repr=False)
    job_id: Optional[int] = None
    log_id: Optional[int] = None

    @property
    def block_number(self) -> int:
        return int(self.receipt["blockNumber"])

    @property
    def gas_used(self) -> int:
        return int(self.receipt["gasUsed"])


class TxSender:
    """Builds, signs and broadcasts contract calls for one account."""

    def __init__(self, w3: Web3, account: LocalAccount | None) -> None:
        self._w3 = w3
        self._account = account

    @property
    def account(self) -> LocalAccount | None:
        return self._account

    @property
    def address(self) -> str:
        if self._account is None:
            raise MissingSignerError("address")
        return self._account.address

    def require_account(self, function_name: str) -> LocalAccount:
        if self._account is None:
            raise MissingSignerError(function_name)
        return self._account

    def fee_params(self) -> dict[str, int]:
        """EIP-1559 fields derived from `eth_feeHistory`, falling back to a legacy gas price."""
        try:
            history = self._w3.eth.fee_history(5, "latest", [50])
            base_fees = [int(f) for f in history["baseFeePerGas"]]
            rewards = [int(r[0]) for r in history.get("reward", []) if r]
        except (Web3Exception, ValueError, KeyError) as exc:  # chain without eth_feeHistory
            logger.debug("eth_feeHistory unavailable (%s); using legacy gasPrice", exc)
            return {"gasPrice": int(self._w3.eth.gas_price)}

        if not base_fees:
            return {"gasPrice": int(self._w3.eth.gas_price)}
        base_fee = base_fees[-1]
        priority = max(rewards) if rewards else MIN_PRIORITY_FEE_WEI
        priority = max(priority, MIN_PRIORITY_FEE_WEI)
        return {"maxPriorityFeePerGas": priority, "maxFeePerGas": base_fee * 2 + priority}

    def send(self, function: ContractFunction, *, value: int = 0, gas: int | None = None) -> TxResult:
        """Estimate gas, sign, broadcast and wait for the receipt. Raises on revert."""
        account = self.require_account(getattr(function, "fn_name", "transaction"))
        params: dict[str, Any] = {
            "from": account.address,
            "nonce": self._w3.eth.get_transaction_count(account.address, "pending"),
            "chainId": self._w3.eth.chain_id,
            "value": value,
        }
        params.update(self.fee_params())
        params["gas"] = gas if gas is not None else self._estimate(function, account.address, value)

        built = function.build_transaction(params)
        signed = account.sign_transaction(built)
        tx_hash = self._w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self._w3.eth.wait_for_transaction_receipt(tx_hash)
        tx_hex = tx_hash.hex() if isinstance(tx_hash, bytes) else str(tx_hash)
        if not tx_hex.startswith("0x"):
            tx_hex = "0x" + tx_hex
        if int(receipt["status"]) != 1:
            raise TransactionFailed(tx_hex, receipt)
        return TxResult(hash=tx_hex, receipt=receipt)

    def _estimate(self, function: ContractFunction, sender: str, value: int) -> int:
        estimated = int(function.estimate_gas({"from": sender, "value": value}))
        scaled = estimated * GAS_BUFFER_NUMERATOR // GAS_BUFFER_DENOMINATOR
        return max(scaled, estimated + GAS_BUFFER_MINIMUM)
