// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
//
// Appendix XIV.D: DTLMFSettlementInsurance.sol — Reorg-Proofing & Conditional Finality
// Final Production Version 1.0 (V1.8 Shariah-Compliant)
//
// Architecture:
//   - Two-Phase Escrow: Capital disbursements suspended for REORG_FINALITY_THRESHOLD blocks.
//   - Automatic Rollback: Returns 100% of locked cost basis if the L1 anchor disappears
//     due to a DAC (Data Availability Committee) partition during the challenge window.
//   - Dispute Resolution: Adjudicator role can override settlement if oracle evidence conflicts.

pragma solidity ^0.8.20;

import {DATToken} from "./DATToken.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// Forward-declare oracle interface (same as in DTLMFSettlement.sol).
interface ISubstrateOracle {
    function anchorExists(bytes32 movementId) external view returns (bool);
    function getManifestValue(bytes32 movementId) external view returns (uint256);
}

/**
 * @title DTLMFSettlementInsurance
 * @notice Provides reorg-proof two-phase escrow finality for Murabaha settlements
 *         on the Arbitrum AnyTrust Layer 2.
 *
 * @dev    Phase 1 (Initiation): Capital is locked in escrow for REORG_FINALITY_THRESHOLD
 *         blocks (~25 minutes at Arbitrum block speed). DAT tokens are issued immediately.
 *
 *         Phase 2 (Confirmation): After the threshold, the relayer or anyone calls
 *         confirmSettlementFinality() to release the escrow. If the L1 anchor has
 *         disappeared (DAC partition / reorg detected by detectLayer2Reorg()), the
 *         escrow is automatically returned to the MSME (automatic rollback).
 *
 *         Dispute: The ADJUDICATOR_ROLE can override and dispute any settlement,
 *         triggering a 7-day resolution window with a locked escrow.
 */
contract DTLMFSettlementInsurance is Ownable, ReentrancyGuard, Pausable {

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @notice Number of blocks to wait before finalising settlement (~25 min on Arbitrum).
    ///         V1.8 Spec: 6,000 blocks.
    uint256 public constant REORG_FINALITY_THRESHOLD = 6_000;

    /// @notice Dispute resolution window in blocks (~7 days on Arbitrum at ~0.25s/block).
    uint256 public constant DISPUTE_RESOLUTION_WINDOW = 2_419_200;

    // =========================================================================
    // ROLES
    // =========================================================================

    /// @notice Address with authority to raise and adjudicate settlement disputes.
    address public adjudicator;

    // =========================================================================
    // DATA STRUCTURES
    // =========================================================================

    enum SettlementPhase {
        Uninitialised,
        Pending,      // Phase 1: Escrow locked, finality window active.
        Finalised,    // Phase 2: Finality confirmed, escrow released.
        Rolled_Back,  // Reorg detected: escrow returned to MSME.
        Disputed,     // Dispute raised by adjudicator.
        Resolved      // Dispute resolved.
    }

    struct EscrowRecord {
        bytes32 movementId;
        address msme;
        uint256 costBasis;          // Principal locked in escrow (wei).
        uint256 totalOwed;          // Total owed including markup.
        uint256 lockedAtBlock;      // Block when escrow was locked.
        SettlementPhase phase;
        bool reorgDetected;
        uint256 disputeRaisedAtBlock;
        string disputeReason;
    }

    /// @notice Registry of all escrow records keyed by movementId.
    mapping(bytes32 => EscrowRecord) public escrows;

    /// @notice Reference to the DAT token contract.
    DATToken public immutable datToken;

    /// @notice Reference to the Substrate L1 oracle.
    ISubstrateOracle public substrateOracle;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event SettlementInitiated(
        bytes32 indexed movementId,
        address indexed msme,
        uint256 costBasis,
        uint256 totalOwed,
        uint256 finalityUnlockBlock
    );

    event SettlementFinalised(bytes32 indexed movementId, uint256 releasedAtBlock);

    event SettlementRolledBack(
        bytes32 indexed movementId,
        address indexed msme,
        uint256 returnedAmount
    );

    event SettlementDisputed(
        bytes32 indexed movementId,
        address indexed adjudicator,
        string reason
    );

    event DisputeResolved(bytes32 indexed movementId, bool upheld);

    event AdjudicatorUpdated(address indexed oldAdjudicator, address indexed newAdjudicator);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(address _datToken, address _oracle, address _adjudicator)
        Ownable(msg.sender)
    {
        require(_datToken != address(0), "Insurance: invalid DAT token");
        require(_oracle != address(0), "Insurance: invalid oracle");
        require(_adjudicator != address(0), "Insurance: invalid adjudicator");
        datToken = DATToken(_datToken);
        substrateOracle = ISubstrateOracle(_oracle);
        adjudicator = _adjudicator;
    }

    // =========================================================================
    // PHASE 1: INITIATE — LOCK ESCROW
    // =========================================================================

    /**
     * @notice Initiates a two-phase escrow-backed settlement for a Murabaha position.
     * @dev    Locks msg.value as the escrow for this settlement's cost basis.
     *         DAT tokens representing totalOwed are minted to the MSME immediately.
     *         Finality is only confirmed after REORG_FINALITY_THRESHOLD blocks.
     * @param movementId    The eFTI Movement ID.
     * @param msme          The MSME's wallet address.
     * @param costBasis     The principal amount to lock in escrow (must equal msg.value).
     * @param totalOwed     The full Murabaha obligation (costBasis + markup).
     */
    function settleWithL1Guarantee(
        bytes32 movementId,
        address msme,
        uint256 costBasis,
        uint256 totalOwed
    )
        external
        payable
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        require(msme != address(0), "Insurance: MSME is zero address");
        require(msg.value == costBasis, "Insurance: escrow must equal costBasis");
        require(totalOwed >= costBasis, "Insurance: totalOwed < costBasis");
        require(
            escrows[movementId].phase == SettlementPhase.Uninitialised,
            "Insurance: escrow already exists"
        );
        require(
            address(substrateOracle) != address(0) &&
            substrateOracle.anchorExists(movementId),
            "Insurance: no L1 anchor verified"
        );

        escrows[movementId] = EscrowRecord({
            movementId: movementId,
            msme: msme,
            costBasis: costBasis,
            totalOwed: totalOwed,
            lockedAtBlock: block.number,
            phase: SettlementPhase.Pending,
            reorgDetected: false,
            disputeRaisedAtBlock: 0,
            disputeReason: ""
        });

        // Mint DAT tokens to MSME immediately upon escrow lock.
        datToken.mint(msme, totalOwed, movementId);

        uint256 unlockBlock = block.number + REORG_FINALITY_THRESHOLD;
        emit SettlementInitiated(movementId, msme, costBasis, totalOwed, unlockBlock);
    }

    // =========================================================================
    // PHASE 2: CONFIRM FINALITY
    // =========================================================================

    /**
     * @notice Confirms settlement finality after the reorg window has passed.
     * @dev    Callable by anyone after REORG_FINALITY_THRESHOLD blocks.
     *         Checks oracle for L1 anchor existence. If anchor is missing (reorg),
     *         automatically triggers rollback. Otherwise, finalises.
     * @param movementId    The eFTI Movement ID.
     */
    function confirmSettlementFinality(bytes32 movementId)
        external
        nonReentrant
        whenNotPaused
    {
        EscrowRecord storage record = escrows[movementId];
        require(record.phase == SettlementPhase.Pending, "Insurance: not in pending phase");
        require(
            block.number >= record.lockedAtBlock + REORG_FINALITY_THRESHOLD,
            "Insurance: finality window not elapsed"
        );

        // Check oracle: if L1 anchor vanished, auto-rollback.
        if (!substrateOracle.anchorExists(movementId)) {
            _executeRollback(movementId, record);
            return;
        }

        record.phase = SettlementPhase.Finalised;
        emit SettlementFinalised(movementId, block.number);
    }

    // =========================================================================
    // REORG DETECTION & ROLLBACK
    // =========================================================================

    /**
     * @notice Detects whether a Layer 2 reorg has invalidated an escrow's L1 anchor.
     * @param movementId    The eFTI Movement ID to check.
     * @return              True if a reorg was detected (anchor no longer exists on L1).
     */
    function detectLayer2Reorg(bytes32 movementId) external view returns (bool) {
        EscrowRecord storage record = escrows[movementId];
        if (record.phase != SettlementPhase.Pending) return false;
        return !substrateOracle.anchorExists(movementId);
    }

    /**
     * @notice Manually triggers an automatic rollback for a detected reorg.
     * @dev    Callable by the owner or adjudicator. Internally calls _executeRollback.
     * @param movementId    The eFTI Movement ID.
     */
    function triggerRollback(bytes32 movementId)
        external
        nonReentrant
        whenNotPaused
    {
        require(
            msg.sender == owner() || msg.sender == adjudicator,
            "Insurance: not authorized"
        );
        EscrowRecord storage record = escrows[movementId];
        require(record.phase == SettlementPhase.Pending, "Insurance: not in pending phase");
        require(!substrateOracle.anchorExists(movementId), "Insurance: anchor still exists, no reorg");
        _executeRollback(movementId, record);
    }

    /// @dev Internal: executes the full rollback, returning cost basis to MSME.
    function _executeRollback(bytes32 movementId, EscrowRecord storage record) internal {
        record.phase = SettlementPhase.Rolled_Back;
        record.reorgDetected = true;

        uint256 returnAmount = record.costBasis;
        address msme = record.msme;

        // Return 100% of the locked cost basis to the MSME.
        (bool success, ) = msme.call{value: returnAmount}("");
        require(success, "Insurance: rollback transfer failed");

        emit SettlementRolledBack(movementId, msme, returnAmount);
    }

    // =========================================================================
    // DISPUTE MANAGEMENT
    // =========================================================================

    /**
     * @notice Raises a dispute against a pending settlement.
     * @dev    Only callable by the adjudicator. Freezes the escrow pending resolution.
     * @param movementId    The eFTI Movement ID.
     * @param reason        Human-readable dispute rationale (logged on-chain).
     */
    function disputeSettlement(bytes32 movementId, string calldata reason)
        external
    {
        require(msg.sender == adjudicator, "Insurance: only adjudicator");
        EscrowRecord storage record = escrows[movementId];
        require(record.phase == SettlementPhase.Pending, "Insurance: not disputable");

        record.phase = SettlementPhase.Disputed;
        record.disputeRaisedAtBlock = block.number;
        record.disputeReason = reason;

        emit SettlementDisputed(movementId, adjudicator, reason);
    }

    /**
     * @notice Resolves a disputed settlement.
     * @dev    If `upheld` is true, the dispute is upheld and funds are rolled back.
     *         If false, the dispute is dismissed and the settlement is finalised.
     * @param movementId    The eFTI Movement ID.
     * @param upheld        Whether the dispute is upheld (true) or dismissed (false).
     */
    function resolveDispute(bytes32 movementId, bool upheld)
        external
        nonReentrant
    {
        require(msg.sender == adjudicator || msg.sender == owner(), "Insurance: not authorized");
        EscrowRecord storage record = escrows[movementId];
        require(record.phase == SettlementPhase.Disputed, "Insurance: not in dispute");

        if (upheld) {
            _executeRollback(movementId, record);
        } else {
            record.phase = SettlementPhase.Resolved;
        }

        emit DisputeResolved(movementId, upheld);
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setAdjudicator(address _new) external onlyOwner {
        emit AdjudicatorUpdated(adjudicator, _new);
        adjudicator = _new;
    }

    function setOracle(address _oracle) external onlyOwner {
        substrateOracle = ISubstrateOracle(_oracle);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {}
}
