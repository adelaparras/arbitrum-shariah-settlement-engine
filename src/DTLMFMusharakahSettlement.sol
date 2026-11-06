// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
//
// Appendix XIV.C: DTLMFMusharakahSettlement.sol — Syndicated Capital Allocation Engine
// Final Production Version 1.0 (V1.8 Shariah-Compliant)
//
// AAOIFI Compliance:
//   - AAOIFI SS-12 (Musharakah): Proportional profit AND loss sharing between capital partners.
//   - Loss Proportionality: Losses swept pro-rata from specific LP vaults at defined ratios.
//   - Mudarib Yield: Managing partner profit share (30.00%) deducted ex-ante from gross profit.
//   - No guaranteed returns: All profit distributions conditioned on actual trade realisation.

pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title DTLMFMusharakahSettlement
 * @notice Manages syndicated capital allocation under AAOIFI SS-12 Musharakah.
 *
 * @dev Capital Partners (LPs) contribute to a shared pool backing a specific
 *      cargo trade finance position. Profits and losses are distributed strictly
 *      in proportion to each LP's capital contribution ratio, enforced on-chain.
 *
 *      Reference Capital Allocation (from V1.8 spec, for a 3-party syndicate):
 *        LP1 (Primary Funder):   62.50% of capital
 *        LP2 (Secondary Funder): 31.25% of capital
 *        Platform Operator:       6.25% of capital  (Mudarib managing partner)
 *
 *      Profit Distribution:
 *        Mudarib fee (Platform): 30.00% of gross profit (ex-ante deduction)
 *        Remaining 70.00% split pro-rata among all LPs by capital contribution.
 *
 *      Loss Distribution:
 *        100% of losses swept pro-rata from LP capital vaults by contribution ratio.
 */
contract DTLMFMusharakahSettlement is Ownable, ReentrancyGuard, Pausable {

    // =========================================================================
    // CONSTANTS — V1.8 CAPITAL ALLOCATION RATIOS (basis points)
    // =========================================================================

    /// @notice Basis point denominator (10_000 = 100.00%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Mudarib (managing partner / Platform Operator) profit share: 30.00%.
    uint256 public constant MUDARIB_PROFIT_SHARE_BPS = 3_000;

    // =========================================================================
    // DATA STRUCTURES
    // =========================================================================

    /// @notice Represents a capital partner's contribution to a Musharakah pool.
    struct CapitalPartner {
        /// The Ethereum address of the LP or Platform Operator.
        address wallet;
        /// Capital contribution in basis points (sum of all partners must equal 10_000).
        uint256 contributionBps;
        /// Current capital vault balance (deposited capital minus applied losses).
        uint256 vaultBalance;
    }

    /// @notice Represents a single Musharakah syndicated capital pool.
    struct MusharakahPool {
        /// The eFTI Movement ID this pool finances.
        bytes32 movementId;
        /// Ordered list of all capital partners (including Platform Operator).
        CapitalPartner[] partners;
        /// Total capital committed to this pool (sum of all partner deposits).
        uint256 totalCapital;
        /// Cumulative gross profit realised for this pool.
        uint256 realisedProfit;
        /// Cumulative losses applied to this pool.
        uint256 realisedLoss;
        /// Whether this pool has been closed.
        bool closed;
        /// Block number at pool creation.
        uint256 createdAtBlock;
    }

    /// @notice Registry mapping movementId to its Musharakah pool.
    mapping(bytes32 => MusharakahPool) public pools;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event PoolCreated(
        bytes32 indexed movementId,
        uint256 totalCapital,
        uint256 partnerCount
    );

    event ProfitsDistributed(
        bytes32 indexed movementId,
        uint256 grossProfit,
        uint256 mudaribFee,
        uint256 lpProfit
    );

    event LossApplied(
        bytes32 indexed movementId,
        uint256 lossAmount,
        uint256 partnerCount
    );

    event PoolClosed(bytes32 indexed movementId);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() Ownable(msg.sender) {}

    // =========================================================================
    // POOL MANAGEMENT
    // =========================================================================

    /**
     * @notice Creates a new Musharakah capital pool for a given eFTI movement.
     * @dev    Validates that all partner contribution basis points sum exactly to 10_000.
     *         Partners array must include the Platform Operator as the last entry.
     * @param movementId        The eFTI Movement ID this pool will finance.
     * @param partnerWallets    Ordered list of LP and Operator wallet addresses.
     * @param contributionBps   Corresponding capital contributions in basis points.
     */
    function createPool(
        bytes32 movementId,
        address[] calldata partnerWallets,
        uint256[] calldata contributionBps
    )
        external
        payable
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        require(pools[movementId].createdAtBlock == 0, "Musharakah: pool already exists");
        require(partnerWallets.length >= 2, "Musharakah: minimum 2 partners required");
        require(
            partnerWallets.length == contributionBps.length,
            "Musharakah: partner/bps array length mismatch"
        );
        require(msg.value > 0, "Musharakah: no capital deposited");

        // Validate that all basis points sum exactly to 10_000.
        uint256 totalBps = 0;
        for (uint256 i = 0; i < contributionBps.length; i++) {
            require(partnerWallets[i] != address(0), "Musharakah: zero address partner");
            totalBps += contributionBps[i];
        }
        require(totalBps == BPS_DENOMINATOR, "Musharakah: contribution bps must sum to 10_000");

        MusharakahPool storage pool = pools[movementId];
        pool.movementId = movementId;
        pool.totalCapital = msg.value;
        pool.createdAtBlock = block.number;

        for (uint256 i = 0; i < partnerWallets.length; i++) {
            uint256 vaultAlloc = (msg.value * contributionBps[i]) / BPS_DENOMINATOR;
            pool.partners.push(CapitalPartner({
                wallet: partnerWallets[i],
                contributionBps: contributionBps[i],
                vaultBalance: vaultAlloc
            }));
        }

        emit PoolCreated(movementId, msg.value, partnerWallets.length);
    }

    // =========================================================================
    // PROFIT DISTRIBUTION
    // =========================================================================

    /**
     * @notice Distributes gross profits from a realised trade to all capital partners.
     *
     * @dev    Distribution Logic (AAOIFI SS-12):
     *         1. Mudarib fee (30.00%) deducted ex-ante from gross profit.
     *         2. Remaining 70.00% distributed to ALL partners pro-rata by contributionBps.
     *            Note: Platform Operator (Mudarib) also receives LP-portion on their capital.
     *         3. No guaranteed minimum returns — profit must be realised first.
     *
     * @param movementId    The pool's movement ID.
     * @param grossProfit   The total gross profit in wei to distribute.
     */
    function distributeProfits(bytes32 movementId, uint256 grossProfit)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        MusharakahPool storage pool = pools[movementId];
        require(pool.createdAtBlock != 0, "Musharakah: pool not found");
        require(!pool.closed, "Musharakah: pool is closed");
        require(grossProfit > 0, "Musharakah: profit must be positive");
        require(address(this).balance >= grossProfit, "Musharakah: insufficient contract balance");

        // Step 1: Deduct Mudarib fee ex-ante (Platform Operator managing partner share).
        uint256 mudaribFee = (grossProfit * MUDARIB_PROFIT_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 lpProfit = grossProfit - mudaribFee;

        pool.realisedProfit += grossProfit;

        // Step 2: Transfer Mudarib fee to the last partner (Platform Operator by convention).
        address mudarib = pool.partners[pool.partners.length - 1].wallet;
        (bool mudaribSuccess, ) = mudarib.call{value: mudaribFee}("");
        require(mudaribSuccess, "Musharakah: mudarib fee transfer failed");

        // Step 3: Distribute remaining LP profit pro-rata by contribution basis points.
        for (uint256 i = 0; i < pool.partners.length; i++) {
            uint256 partnerShare = (lpProfit * pool.partners[i].contributionBps) / BPS_DENOMINATOR;
            if (partnerShare > 0) {
                (bool success, ) = pool.partners[i].wallet.call{value: partnerShare}("");
                require(success, "Musharakah: LP profit transfer failed");
            }
        }

        emit ProfitsDistributed(movementId, grossProfit, mudaribFee, lpProfit);
    }

    // =========================================================================
    // LOSS APPLICATION
    // =========================================================================

    /**
     * @notice Applies a cargo loss to all capital partners proportionally.
     *
     * @dev    Loss Distribution Logic (AAOIFI SS-12):
     *         Losses are swept pro-rata from each partner's capital vault balance
     *         according to their contributionBps ratio. No single partner bears
     *         disproportionate loss (no loss guarantee / mudarib protection).
     *         If a partner's vault balance is insufficient, their vault is zeroed.
     *
     * @param movementId    The pool's movement ID.
     * @param lossAmount    The total loss amount in wei to distribute.
     */
    function applyCargoLoss(bytes32 movementId, uint256 lossAmount)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        MusharakahPool storage pool = pools[movementId];
        require(pool.createdAtBlock != 0, "Musharakah: pool not found");
        require(!pool.closed, "Musharakah: pool is closed");
        require(lossAmount > 0, "Musharakah: loss must be positive");

        pool.realisedLoss += lossAmount;

        // Sweep loss proportionally from each partner's capital vault.
        for (uint256 i = 0; i < pool.partners.length; i++) {
            uint256 partnerLoss = (lossAmount * pool.partners[i].contributionBps) / BPS_DENOMINATOR;
            if (partnerLoss >= pool.partners[i].vaultBalance) {
                pool.partners[i].vaultBalance = 0;
            } else {
                pool.partners[i].vaultBalance -= partnerLoss;
            }
        }

        emit LossApplied(movementId, lossAmount, pool.partners.length);
    }

    // =========================================================================
    // POOL CLOSURE
    // =========================================================================

    /// @notice Closes a Musharakah pool. Must be called after all distributions.
    function closePool(bytes32 movementId) external onlyOwner {
        MusharakahPool storage pool = pools[movementId];
        require(pool.createdAtBlock != 0, "Musharakah: pool not found");
        require(!pool.closed, "Musharakah: already closed");
        pool.closed = true;
        emit PoolClosed(movementId);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /// @notice Returns the number of capital partners in a pool.
    function getPartnerCount(bytes32 movementId) external view returns (uint256) {
        return pools[movementId].partners.length;
    }

    /// @notice Returns a partner's wallet, contribution bps, and vault balance by index.
    function getPartner(bytes32 movementId, uint256 index)
        external
        view
        returns (address wallet, uint256 contributionBps, uint256 vaultBalance)
    {
        CapitalPartner storage p = pools[movementId].partners[index];
        return (p.wallet, p.contributionBps, p.vaultBalance);
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    receive() external payable {}
}
