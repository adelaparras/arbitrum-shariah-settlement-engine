// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {DTLMFTakafulPool} from "./DTLMFTakafulPool.sol";

/**
 * @title ShariahMultiSigAdjudicator
 * @notice 3-of-5 Multi-Signature Adjudication Engine for DTLMFTakafulPool loss claims.
 *
 * @dev Enforces strict AAOIFI governance:
 *      - 5 independent Shariah Supervisory Board members (Scholars).
 *      - Quorum threshold: 3 approvals required to adjudicate any loss claim.
 *      - Prevents unilateral claim decisions, front-running, and unauthorized payouts.
 */
contract ShariahMultiSigAdjudicator is Ownable, ReentrancyGuard {

    // =========================================================================
    // CONSTANTS & CONFIGURATION
    // =========================================================================

    uint256 public constant TOTAL_SCHOLARS = 5;
    uint256 public constant QUORUM_THRESHOLD = 3;

    DTLMFTakafulPool public immutable takafulPool;

    address[5] public scholars;
    mapping(address => bool) public isScholar;

    struct AdjudicationProposal {
        uint256 claimId;
        bool approve;
        uint256 approvalCount;
        bool executed;
        bytes32 reasonHash;
    }

    uint256 public proposalCounter;
    mapping(uint256 => AdjudicationProposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event ProposalCreated(uint256 indexed proposalId, uint256 indexed claimId, bool approve, address proposer);
    event ProposalVoted(uint256 indexed proposalId, address indexed scholar, uint256 totalVotes);
    event ProposalExecuted(uint256 indexed proposalId, uint256 indexed claimId, bool approved);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyScholar() {
        require(isScholar[msg.sender], "ShariahMultiSig: caller is not a Shariah scholar");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(
        address _takafulPool,
        address[5] memory _scholars
    ) Ownable(msg.sender) {
        require(_takafulPool != address(0), "ShariahMultiSig: invalid pool address");
        takafulPool = DTLMFTakafulPool(payable(_takafulPool));

        for (uint256 i = 0; i < 5; i++) {
            address scholar = _scholars[i];
            require(scholar != address(0), "ShariahMultiSig: zero address scholar");
            require(!isScholar[scholar], "ShariahMultiSig: duplicate scholar");

            scholars[i] = scholar;
            isScholar[scholar] = true;
        }
    }

    // =========================================================================
    // MULTI-SIG ADJUDICATION LIFECYCLE
    // =========================================================================

    /**
     * @notice Proposes a claim adjudication (Approve or Reject) for a filed claim.
     * @param claimId       The ID of the claim in DTLMFTakafulPool.
     * @param approve       Whether the Shariah board should approve (true) or reject (false).
     * @param reasonHash    Keccak256 hash of the Shariah legal ruling (Fatwa/Fiqh justification).
     */
    function proposeAdjudication(
        uint256 claimId,
        bool approve,
        bytes32 reasonHash
    ) external onlyScholar returns (uint256 proposalId) {
        proposalId = proposalCounter++;

        proposals[proposalId] = AdjudicationProposal({
            claimId: claimId,
            approve: approve,
            approvalCount: 1,
            executed: false,
            reasonHash: reasonHash
        });

        hasVoted[proposalId][msg.sender] = true;

        emit ProposalCreated(proposalId, claimId, approve, msg.sender);
        emit ProposalVoted(proposalId, msg.sender, 1);
    }

    /**
     * @notice Casts an affirmative vote on an open adjudication proposal.
     * @param proposalId The proposal identifier to confirm.
     */
    function confirmAdjudication(uint256 proposalId) external onlyScholar nonReentrant {
        AdjudicationProposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "ShariahMultiSig: proposal already executed");
        require(!hasVoted[proposalId][msg.sender], "ShariahMultiSig: scholar already voted");

        hasVoted[proposalId][msg.sender] = true;
        proposal.approvalCount++;

        emit ProposalVoted(proposalId, msg.sender, proposal.approvalCount);

        // Auto-execute if threshold reached
        if (proposal.approvalCount >= QUORUM_THRESHOLD) {
            _executeProposal(proposalId);
        }
    }

    /**
     * @dev Internal executor invoking the Takaful pool claim adjudication.
     */
    function _executeProposal(uint256 proposalId) internal {
        AdjudicationProposal storage proposal = proposals[proposalId];
        proposal.executed = true;

        takafulPool.adjudicateClaim(proposal.claimId, proposal.approve);

        emit ProposalExecuted(proposalId, proposal.claimId, proposal.approve);
    }
}
