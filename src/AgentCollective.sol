// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAgentCollective} from "./interfaces/IAgentCollective.sol";

/// @notice Purpose-built collectives for AI agent groups. Pool resources, share profits, vote on strategy.
contract AgentCollective is ERC1155, Ownable, ReentrancyGuard, Pausable, IAgentCollective {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PROFIT_SHARE_BPS = 5000;
    uint256 public constant MAX_COLLECTIVE_TYPE = 4;
    uint256 public constant LOCK_PERIOD = 30 days;
    uint256 public constant DISTRIBUTION_COOLDOWN = 7 days;
    uint256 public constant AUM_BPS = 5;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_PROPOSAL_DURATION = 1 hours;

    IERC20 public immutable paymentToken;
    uint256 public immutable deploymentFee;

    address public treasury;
    uint256 public collectiveCount;
    uint256 public accumulatedEthFees;
    uint256 public accumulatedUsdcFees;

    mapping(uint256 => Collective) private _collectives;
    mapping(uint256 => address[]) private _members;
    mapping(uint256 => mapping(address => uint256)) private _memberIndex;
    mapping(uint256 => mapping(address => uint48)) private _joinTimestamp;
    mapping(uint256 => uint48) private _lastDistribution;
    mapping(uint256 => uint48) private _lastFeeCollection;

    mapping(uint256 => mapping(uint256 => Proposal)) private _proposals;
    mapping(uint256 => uint256) private _proposalCount;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) private _voted;
    mapping(uint256 => mapping(address => uint256)) private _pendingDistribution;

    constructor(
        IERC20 paymentToken_,
        address treasury_,
        address owner_,
        uint256 deploymentFee_
    ) ERC1155("") Ownable(owner_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        treasury = treasury_;
        deploymentFee = deploymentFee_;
    }

    // ─── Soulbound ERC-1155 ─────────────────────────────────────────────

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0) && to != address(0)) revert SoulboundToken();
        super._update(from, to, ids, values);
    }

    // ─── Create Collective ──────────────────────────────────────────────

    function createCollective(
        string calldata name,
        uint8 collectiveType,
        uint256 entryFee,
        uint256 profitShareBps
    ) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (bytes(name).length == 0) revert EmptyName();
        if (collectiveType > MAX_COLLECTIVE_TYPE) revert InvalidCollectiveType(collectiveType);
        if (profitShareBps > MAX_PROFIT_SHARE_BPS) revert InvalidProfitShare(profitShareBps);
        if (msg.value < deploymentFee) revert InsufficientFee(deploymentFee, msg.value);

        id = collectiveCount++;
        _collectives[id] = Collective({
            name: name,
            collectiveType: collectiveType,
            entryFee: entryFee,
            profitShareBps: profitShareBps,
            treasury: 0,
            memberCount: 0,
            createdAt: uint48(block.timestamp),
            active: true
        });

        _lastFeeCollection[id] = uint48(block.timestamp);
        _lastDistribution[id] = uint48(block.timestamp);
        accumulatedEthFees += msg.value;

        emit CollectiveCreated(id, name, collectiveType, entryFee, profitShareBps);
    }

    // ─── Join Collective ────────────────────────────────────────────────

    function joinCollective(uint256 id) external nonReentrant whenNotPaused {
        Collective storage c = _getActive(id);
        if (balanceOf(msg.sender, id) > 0) revert AlreadyMember(id, msg.sender);

        _chargeAumFee(id);

        if (c.entryFee > 0) {
            c.treasury += c.entryFee;
            paymentToken.safeTransferFrom(msg.sender, address(this), c.entryFee);
        }

        c.memberCount++;
        _memberIndex[id][msg.sender] = _members[id].length;
        _members[id].push(msg.sender);
        _joinTimestamp[id][msg.sender] = uint48(block.timestamp);
        _mint(msg.sender, id, 1, "");

        emit MemberJoined(id, msg.sender);
    }

    // ─── Leave Collective ───────────────────────────────────────────────

    function leaveCollective(uint256 id) external nonReentrant {
        Collective storage c = _getValid(id);
        if (balanceOf(msg.sender, id) == 0) revert NotMember(id, msg.sender);

        _chargeAumFee(id);

        uint256 payout;
        bool pastLock = block.timestamp >= uint256(_joinTimestamp[id][msg.sender]) + LOCK_PERIOD;
        if (pastLock && c.treasury > 0 && c.memberCount > 0) {
            payout = c.treasury / c.memberCount;
            c.treasury -= payout;
        }

        c.memberCount--;
        _removeMember(id, msg.sender);
        _burn(msg.sender, id, 1);

        if (payout > 0) {
            paymentToken.safeTransfer(msg.sender, payout);
        }

        emit MemberLeft(id, msg.sender, payout);
    }

    // ─── Deposit Revenue ────────────────────────────────────────────────

    function depositRevenue(uint256 id, uint256 amount) external nonReentrant {
        Collective storage c = _getActive(id);
        if (balanceOf(msg.sender, id) == 0) revert NotMember(id, msg.sender);
        if (amount == 0) revert ZeroAmount();

        _chargeAumFee(id);
        c.treasury += amount;
        paymentToken.safeTransferFrom(msg.sender, address(this), amount);

        emit RevenueDeposited(id, msg.sender, amount);
    }

    // ─── Distribute Profit ──────────────────────────────────────────────

    function distributeProfit(uint256 id) external nonReentrant {
        Collective storage c = _getActive(id);
        if (c.memberCount == 0) revert NoMembers(id);
        if (c.treasury == 0) revert EmptyTreasury(id);
        if (block.timestamp < uint256(_lastDistribution[id]) + DISTRIBUTION_COOLDOWN) {
            revert DistributionCooldown(id);
        }

        _chargeAumFee(id);

        uint256 distributable = c.treasury.mulDiv(c.profitShareBps, BPS, Math.Rounding.Floor);
        if (distributable == 0) revert EmptyTreasury(id);

        uint256 perMember = distributable / c.memberCount;
        uint256 totalPaid = perMember * c.memberCount;
        c.treasury -= totalPaid;
        _lastDistribution[id] = uint48(block.timestamp);

        address[] storage members = _members[id];
        for (uint256 i; i < members.length; i++) {
            _pendingDistribution[id][members[i]] += perMember;
        }

        emit ProfitDistributed(id, totalPaid, perMember);
    }

    function claimDistribution(uint256 id) external nonReentrant {
        uint256 amount = _pendingDistribution[id][msg.sender];
        if (amount == 0) revert NoPendingDistribution(id, msg.sender);

        _pendingDistribution[id][msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);

        emit DistributionClaimed(id, msg.sender, amount);
    }

    // ─── Voting ─────────────────────────────────────────────────────────

    function createProposal(
        uint256 id,
        string calldata title,
        uint48 deadline
    ) external returns (uint256 proposalId) {
        _getActive(id);
        if (balanceOf(msg.sender, id) == 0) revert NotMember(id, msg.sender);
        if (bytes(title).length == 0) revert EmptyName();
        if (deadline < uint48(block.timestamp) + uint48(MIN_PROPOSAL_DURATION)) revert ProposalDeadlineTooSoon();

        proposalId = _proposalCount[id]++;
        _proposals[id][proposalId] = Proposal({
            title: title,
            deadline: deadline,
            forVotes: 0,
            againstVotes: 0
        });

        emit ProposalCreated(id, proposalId, title, deadline);
    }

    function voteOnStrategy(uint256 id, uint256 proposalId, bool support) external {
        _getActive(id);
        if (balanceOf(msg.sender, id) == 0) revert NotMember(id, msg.sender);
        if (proposalId >= _proposalCount[id]) revert ProposalNotFound(id, proposalId);

        Proposal storage p = _proposals[id][proposalId];
        if (uint48(block.timestamp) >= p.deadline) revert ProposalExpired(id, proposalId);
        if (_voted[id][proposalId][msg.sender]) revert AlreadyVoted(id, proposalId, msg.sender);

        _voted[id][proposalId][msg.sender] = true;

        if (support) {
            p.forVotes++;
        } else {
            p.againstVotes++;
        }

        emit VoteCast(id, proposalId, msg.sender, support);
    }

    // ─── Emergency Withdraw ─────────────────────────────────────────────

    function emergencyWithdraw(uint256 id) external nonReentrant {
        require(paused(), "not paused");
        Collective storage c = _getValid(id);
        if (balanceOf(msg.sender, id) == 0) revert NotMember(id, msg.sender);

        uint256 payout;
        if (c.treasury > 0 && c.memberCount > 0) {
            payout = c.treasury / c.memberCount;
            c.treasury -= payout;
        }

        c.memberCount--;
        _removeMember(id, msg.sender);
        _burn(msg.sender, id, 1);

        if (payout > 0) {
            paymentToken.safeTransfer(msg.sender, payout);
        }

        emit EmergencyWithdrawal(id, msg.sender, payout);
    }

    // ─── Fee Collection ─────────────────────────────────────────────────

    function collectFees() external nonReentrant {
        uint256 ethAmt = accumulatedEthFees;
        uint256 usdcAmt = accumulatedUsdcFees;
        if (ethAmt == 0 && usdcAmt == 0) revert NoFeesToCollect();

        accumulatedEthFees = 0;
        accumulatedUsdcFees = 0;

        if (ethAmt > 0) {
            (bool ok,) = treasury.call{value: ethAmt}("");
            require(ok, "ETH transfer failed");
        }
        if (usdcAmt > 0) {
            paymentToken.safeTransfer(treasury, usdcAmt);
        }
        emit FeesCollected(ethAmt, usdcAmt, treasury);
    }

    // ─── Admin ──────────────────────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── View ───────────────────────────────────────────────────────────

    function getCollective(uint256 id) external view returns (Collective memory) {
        if (id >= collectiveCount) revert InvalidCollective(id);
        return _collectives[id];
    }

    function getMembers(uint256 id) external view returns (address[] memory) {
        return _members[id];
    }

    function getMemberShare(uint256 id, address member) external view returns (uint256) {
        Collective storage c = _collectives[id];
        if (balanceOf(member, id) == 0) return 0;
        if (c.memberCount == 0) return 0;
        return c.treasury / c.memberCount;
    }

    function getProposal(uint256 id, uint256 proposalId) external view returns (Proposal memory) {
        if (proposalId >= _proposalCount[id]) revert ProposalNotFound(id, proposalId);
        return _proposals[id][proposalId];
    }

    function getProposalCount(uint256 id) external view returns (uint256) {
        return _proposalCount[id];
    }

    function getPendingDistribution(uint256 id, address member) external view returns (uint256) {
        return _pendingDistribution[id][member];
    }

    function hasVotedOnProposal(uint256 id, uint256 proposalId, address voter) external view returns (bool) {
        return _voted[id][proposalId][voter];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _chargeAumFee(uint256 id) internal {
        Collective storage c = _collectives[id];
        uint48 lastCharge = _lastFeeCollection[id];
        uint256 elapsed = block.timestamp - uint256(lastCharge);
        if (elapsed == 0 || c.treasury == 0) return;

        uint256 fee = c.treasury.mulDiv(AUM_BPS * elapsed, BPS * SECONDS_PER_YEAR, Math.Rounding.Floor);
        if (fee == 0) return;
        if (fee > c.treasury) fee = c.treasury;

        c.treasury -= fee;
        accumulatedUsdcFees += fee;
        _lastFeeCollection[id] = uint48(block.timestamp);

        emit AumFeeCharged(id, fee);
    }

    function _removeMember(uint256 id, address member) internal {
        uint256 idx = _memberIndex[id][member];
        uint256 last = _members[id].length - 1;
        if (idx != last) {
            address lastMember = _members[id][last];
            _members[id][idx] = lastMember;
            _memberIndex[id][lastMember] = idx;
        }
        _members[id].pop();
        delete _memberIndex[id][member];
        delete _joinTimestamp[id][member];
    }

    function _getValid(uint256 id) internal view returns (Collective storage) {
        if (id >= collectiveCount) revert InvalidCollective(id);
        return _collectives[id];
    }

    function _getActive(uint256 id) internal view returns (Collective storage) {
        Collective storage c = _getValid(id);
        if (!c.active) revert InactiveCollective(id);
        return c;
    }
}
