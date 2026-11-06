// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
//
// Appendix XIV.E: DTLMFTakafulPool.sol — Mutual Guarantee / Risk Hedge Pool
// Final Production Version 1.0 (V1.8 Shariah-Compliant)
//
// AAOIFI Compliance:
//   - AAOIFI FAS-26 (Takaful): Segregated Amanah (trust) pool for participants.
//   - Wakala Model: Operator deducts 10% of each premium as Wakala agency fee.
//   - Premium Splits: 90.00% → participantPoolBalance (Amanah), 10.00% → operatorVault.
//   - Surplus Distribution: 100% of unspent reserves returned to contributors pro-rata.
//   - No Riba: Zero guaranteed returns; all surplus derived from actual underwriting cycle.

pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title DTLMFTakafulPool
 * @notice Implements a Wakala-model Takaful mutual guarantee pool for DTLMF trade participants.
 *
 * @dev    Architecture:
 *         - Economic Operators (EOs) contribute premiums at the start of a trade cycle.
 *         - Premiums are split: 90% to the Amanah participant pool, 10% to operator vault (Wakala fee).
 *         - Loss claims are adjudicated and paid from the Amanah pool.
 *         - At cycle end, any unspent Amanah balance is swept back to contributors pro-rata.
 *         - The operator vault (Wakala fee) is retained by the Platform Operator.
 *
 *         Claim Adjudication:
 *         - CLAIM_ADJUDICATOR_ROLE reviews submitted loss claims.
 *         - Approved claims are paid from participantPoolBalance.
 *         - Rejected claims emit a ClaimRejected event.
 */
contract DTLMFTakafulPool is Ownable, ReentrancyGuard, Pausable {

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @notice Basis point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Wakala operator fee in basis points: 10.00%.
    uint256 public constant WAKALA_FEE_BPS = 1_000;

    /// @notice Participant pool allocation in basis points: 90.00%.
    uint256 public constant PARTICIPANT_POOL_BPS = 9_000;

    /// @notice Maximum single claim payout as fraction of pool (5000 bps = 50%).
    uint256 public constant MAX_CLAIM_BPS = 5_000;

    // =========================================================================
    // STATE
    // =========================================================================

    /// @notice Address of the Takaful adjudicator (loss claim reviewer).
    address public adjudicator;

    /// @notice Amanah (trust) pool balance — holds participant contributions.
    uint256 public participantPoolBalance;

    /// @notice Operator vault balance — holds accumulated Wakala fees.
    uint256 public operatorVaultBalance;

    /// @notice Whether the current underwriting cycle is open for contributions.
    bool public cycleOpen;

    /// @notice The block number when the current cycle was opened.
    uint256 public cycleStartBlock;

    // =========================================================================
    // PARTICIPANT TRACKING
    // =========================================================================

    /// @notice Maps participant address to their contributed premium amount (Amanah portion only).
    mapping(address => uint256) public participantContributions;

    /// @notice Ordered list of all participants in the current cycle.
    address[] public participants;

    /// @notice Tracks whether an address has already contributed in this cycle.
    mapping(address => bool) public hasContributed;

    // =========================================================================
    // CLAIM TRACKING
    // =========================================================================

    enum ClaimStatus { Pending, Approved, Rejected }

    struct LossClaim {
        bytes32 movementId;
        address claimant;
        uint256 claimAmount;
        ClaimStatus status;
        uint256 submittedAtBlock;
        string evidence;
    }

    uint256 public claimCounter;
    mapping(uint256 => LossClaim) public claims;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event CycleOpened(uint256 startBlock);
    event CycleClosed(uint256 endBlock);

    event PremiumContributed(
        address indexed participant,
        uint256 grossPremium,
        uint256 amanahAmount,
        uint256 wakalaFee
    );

    event ClaimFiled(
        uint256 indexed claimId,
        bytes32 indexed movementId,
        address indexed claimant,
        uint256 claimAmount
    );

    event ClaimAdjudicated(uint256 indexed claimId, ClaimStatus status, uint256 paidAmount);

    event SurplusDistributed(uint256 totalSurplus, uint256 participantCount);

    event WakalaFeeWithdrawn(address indexed operator, uint256 amount);

    event AdjudicatorUpdated(address indexed old_, address indexed new_);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(address _adjudicator) Ownable(msg.sender) {
        require(_adjudicator != address(0), "Takaful: invalid adjudicator");
        adjudicator = _adjudicator;
    }

    // =========================================================================
    // CYCLE MANAGEMENT
    // =========================================================================

    /// @notice Opens a new underwriting cycle. Only callable by owner.
    function openCycle() external onlyOwner {
        require(!cycleOpen, "Takaful: cycle already open");
        cycleOpen = true;
        cycleStartBlock = block.number;
        emit CycleOpened(block.number);
    }

    /// @notice Closes the current underwriting cycle. Stops new contributions.
    function closeCycle() external onlyOwner {
        require(cycleOpen, "Takaful: cycle not open");
        cycleOpen = false;
        emit CycleClosed(block.number);
    }

    // =========================================================================
    // PREMIUM CONTRIBUTION
    // =========================================================================

    /**
     * @notice Contributes a premium to the Takaful pool on behalf of an Economic Operator.
     *
     * @dev    Premium Split (AAOIFI FAS-26 Wakala Model):
     *           90% → participantPoolBalance (Amanah trust)
     *           10% → operatorVaultBalance (Wakala agency fee)
     *
     *         Each participant may contribute only once per cycle to prevent gaming.
     *         Contributions during a closed cycle are rejected.
     *
     * @param participant   The Economic Operator contributing the premium.
     */
    function contributePremium(address participant)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(cycleOpen, "Takaful: cycle is closed");
        require(participant != address(0), "Takaful: zero address participant");
        require(msg.value > 0, "Takaful: premium must be positive");
        require(!hasContributed[participant], "Takaful: already contributed this cycle");

        uint256 grossPremium = msg.value;

        // Split the premium.
        uint256 wakalaFee = (grossPremium * WAKALA_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amanahAmount = grossPremium - wakalaFee;

        participantPoolBalance += amanahAmount;
        operatorVaultBalance += wakalaFee;

        // Track contribution.
        participantContributions[participant] += amanahAmount;
        if (!hasContributed[participant]) {
            participants.push(participant);
        }
        hasContributed[participant] = true;

        emit PremiumContributed(participant, grossPremium, amanahAmount, wakalaFee);
    }

    // =========================================================================
    // LOSS CLAIMS
    // =========================================================================

    /**
     * @notice Files a loss claim against the Takaful pool.
     * @dev    Any registered participant can file a claim for a specific movementId.
     *         Claims are queued for adjudication; no automatic payout.
     * @param movementId    The eFTI Movement ID associated with the cargo loss.
     * @param claimAmount   The claimed loss amount in wei.
     * @param evidence      IPFS CID or URI pointing to the loss evidence document.
     */
    function fileLossClaim(
        bytes32 movementId,
        uint256 claimAmount,
        string calldata evidence
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 claimId)
    {
        require(hasContributed[msg.sender], "Takaful: not a pool participant");
        require(claimAmount > 0, "Takaful: claim must be positive");
        require(
            claimAmount <= (participantPoolBalance * MAX_CLAIM_BPS) / BPS_DENOMINATOR,
            "Takaful: claim exceeds maximum payout cap"
        );

        claimId = claimCounter++;

        claims[claimId] = LossClaim({
            movementId: movementId,
            claimant: msg.sender,
            claimAmount: claimAmount,
            status: ClaimStatus.Pending,
            submittedAtBlock: block.number,
            evidence: evidence
        });

        emit ClaimFiled(claimId, movementId, msg.sender, claimAmount);
    }

    // =========================================================================
    // CLAIM ADJUDICATION
    // =========================================================================

    /**
     * @notice Adjudicates a pending loss claim.
     *
     * @dev    Only callable by the adjudicator.
     *         If approved, the claim amount is transferred from participantPoolBalance
     *         to the claimant. If the pool balance is insufficient, the claim is
     *         partially paid up to available balance.
     *         If rejected, no funds are moved.
     *
     * @param claimId   The claim ID to adjudicate.
     * @param approve   True to approve and pay; false to reject.
     */
    function adjudicateClaim(uint256 claimId, bool approve)
        external
        nonReentrant
    {
        require(msg.sender == adjudicator, "Takaful: only adjudicator");
        LossClaim storage claim = claims[claimId];
        require(claim.status == ClaimStatus.Pending, "Takaful: claim not pending");

        if (approve) {
            claim.status = ClaimStatus.Approved;
            uint256 payout = claim.claimAmount;

            // Pay up to available pool balance.
            if (payout > participantPoolBalance) {
                payout = participantPoolBalance;
            }
            participantPoolBalance -= payout;

            (bool success, ) = claim.claimant.call{value: payout}("");
            require(success, "Takaful: claim payout transfer failed");

            emit ClaimAdjudicated(claimId, ClaimStatus.Approved, payout);
        } else {
            claim.status = ClaimStatus.Rejected;
            emit ClaimAdjudicated(claimId, ClaimStatus.Rejected, 0);
        }
    }

    // =========================================================================
    // SURPLUS DISTRIBUTION
    // =========================================================================

    /**
     * @notice Distributes any remaining Amanah pool balance back to contributors pro-rata.
     *
     * @dev    Called at the end of an underwriting cycle after all claims are adjudicated.
     *         The surplus is the remaining participantPoolBalance after all approved payouts.
     *         Each participant receives: (their contribution / totalContributions) * surplus.
     *         The operator vault (Wakala fee) is NOT included in surplus — it is retained.
     *
     *         IMPORTANT: This function resets the pool state for the next cycle.
     */
    function distributePoolSurplus()
        external
        onlyOwner
        nonReentrant
    {
        require(!cycleOpen, "Takaful: close cycle before distributing surplus");
        require(participantPoolBalance > 0, "Takaful: no surplus to distribute");
        require(participants.length > 0, "Takaful: no participants");

        // Stack-cache initialPoolBalance to lock division basis and eliminate underflow panics
        uint256 initialPoolBalance = participantPoolBalance;
        uint256 totalSurplus = initialPoolBalance;
        uint256 totalContributed = 0;
        uint256 participantCount = participants.length;

        // Calculate total Amanah contributions.
        for (uint256 i = 0; i < participantCount; i++) {
            totalContributed += participantContributions[participants[i]];
        }
        require(totalContributed > 0, "Takaful: no contributions recorded");

        // Zero out participantPoolBalance before external transfers (Checks-Effects-Interactions pattern)
        participantPoolBalance = 0;

        // Distribute surplus pro-rata by each participant's Amanah contribution.
        for (uint256 i = 0; i < participantCount; i++) {
            address p = participants[i];
            uint256 contribution = participantContributions[p];
            if (contribution == 0) continue;

            uint256 share = (totalSurplus * contribution) / totalContributed;
            if (share > 0) {
                (bool success, ) = p.call{value: share}("");
                require(success, "Takaful: surplus transfer failed");
            }

            // Reset participant state for next cycle.
            participantContributions[p] = 0;
            hasContributed[p] = false;
        }

        delete participants;

        emit SurplusDistributed(totalSurplus, participantCount);
    }

    // =========================================================================
    // OPERATOR VAULT WITHDRAWAL
    // =========================================================================

    /**
     * @notice Allows the owner to withdraw accumulated Wakala fees from the operator vault.
     * @param amount    Amount to withdraw in wei.
     */
    function withdrawWakalaFees(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= operatorVaultBalance, "Takaful: insufficient vault balance");
        operatorVaultBalance -= amount;
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Takaful: vault withdrawal failed");
        emit WakalaFeeWithdrawn(owner(), amount);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /// @notice Returns the total number of participants in the current cycle.
    function getParticipantCount() external view returns (uint256) {
        return participants.length;
    }

    /// @notice Returns claim details for a given claim ID.
    function getClaim(uint256 claimId) external view returns (LossClaim memory) {
        return claims[claimId];
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setAdjudicator(address _new) external onlyOwner {
        require(_new != address(0), "Takaful: zero address");
        emit AdjudicatorUpdated(adjudicator, _new);
        adjudicator = _new;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {}
}
