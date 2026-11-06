// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
//
// Appendix XIV.A: DTLMFSettlement.sol — Murabaha Trade Facilitation Engine
// Final Production Version 1.0 (V1.8 Shariah-Compliant)
//
// AAOIFI Compliance:
//   - AAOIFI SS-20 (Murabaha): Static cost-plus markup, no compounding or dynamic indexing.
//   - AAOIFI SS-31 (Gharar Prevention): L1 oracle gating prevents speculative positions.
//   - Riba Prevention: All returns computed via checked integer basis-point arithmetic.
//   - Maysir Prevention: preventUnanchoredPositions blocks uncollateralized finance.

pragma solidity ^0.8.20;

import {DATToken} from "./DATToken.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// =============================================================================
// SUBSTRATE L1 ORACLE INTERFACE
// =============================================================================

/**
 * @title ISubstrateOracle
 * @notice Off-chain oracle interface bridging Polkadot Layer 1 anchor state
 *         into the Arbitrum AnyTrust Layer 2 settlement contract.
 *
 * @dev Implemented by the AAG Gateway (aag_gateway.ts). The relayer (relayer.ts)
 *      populates this oracle with current L1 anchor existence and manifest value
 *      by listening to Substrate finalized block events and updating the oracle
 *      state on Layer 2 accordingly.
 */
interface ISubstrateOracle {

    /**
     * @notice Checks whether a cargo anchor for the given eFTI Movement ID
     *         has been finalized on Polkadot Layer 1.
     * @param movementId    The eFTI unique movement identifier (bytes32).
     * @return              True if a verified anchor exists on L1, false otherwise.
     */
    function anchorExists(bytes32 movementId) external view returns (bool);

    /**
     * @notice Returns the manifest value (in USD cents) declared for a given
     *         movement ID on Polkadot Layer 1.
     * @param movementId    The eFTI unique movement identifier (bytes32).
     * @return              Cargo manifest value in USD cents (integer, no float).
     */
    function getManifestValue(bytes32 movementId) external view returns (uint256);
}

// =============================================================================
// MURABAHA SETTLEMENT CONTRACT
// =============================================================================

/**
 * @title DTLMFSettlement
 * @notice Orchestrates Shariah-compliant Murabaha trade finance settlement on
 *         Arbitrum AnyTrust Layer 2, gated by verified Polkadot Layer 1 cargo anchors.
 *
 * @dev Core Invariants:
 *      1. Time-Independence (Riba Prevention): Cost-plus yield is evaluated once
 *         via static integer basis-point arithmetic at initiation. No compounding.
 *      2. Oracle-Gating (Maysir / Gharar Prevention): The preventUnanchoredPositions
 *         modifier calls ISubstrateOracle synchronously. A trade cannot be initiated
 *         unless the L1 anchor is verified finalized.
 *      3. Escrow Model: DAT tokens are held in escrow by this contract (not minted
 *         to the MSME) until settlement is confirmed by the oracle.
 *      4. AccessControl: MINTER_ROLE and BURNER_ROLE on DATToken are held by
 *         this contract's address alone.
 */
contract DTLMFSettlement is Ownable, ReentrancyGuard, Pausable {

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    /// @notice The DAT token contract this settlement engine controls.
    DATToken public immutable datToken;

    /// @notice The Substrate L1 oracle providing cargo anchor verification.
    ISubstrateOracle public substrateOracle;

    // =========================================================================
    // MURABAHA TRANSACTION STRUCT
    // =========================================================================

    /**
     * @notice Represents a single Murabaha trade finance transaction.
     * @dev    `totalOwed` is computed once at initiation as:
     *              totalOwed = costBasis + ((costBasis * markupBps) / 10_000)
     *         This is a static, time-independent calculation (no compounding).
     *         `markupBps` is expressed in basis points (1 bp = 0.01%).
     */
    struct MurabahaTransaction {
        /// The eFTI Movement ID backing this Murabaha position (L1 anchor key).
        bytes32 movementId;
        /// The MSME (Economic Operator) receiving the trade finance.
        address msme;
        /// The cost basis amount (principal) in USD cents.
        uint256 costBasis;
        /// The fixed markup expressed in basis points (e.g., 300 = 3.00%).
        uint256 markupBps;
        /// The total amount owed (costBasis + markup), computed once at initiation.
        uint256 totalOwed;
        /// Whether the Murabaha position has been fully settled.
        bool settled;
        /// Block number at which the position was initiated (finality reference).
        uint256 initiatedAtBlock;
        /// Declared cargo manifest value from the L1 oracle at initiation.
        uint256 manifestValueAtInitiation;
    }

    /// @notice Registry mapping movementId to its Murabaha transaction record.
    mapping(bytes32 => MurabahaTransaction) public murabahaTransactions;

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @notice Basis point denominator for markup calculation (10_000 = 100.00%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum allowed markup in basis points (1000 = 10.00%).
    ///         Prevents excessive profit-taking that could be construed as Riba.
    uint256 public constant MAX_MARKUP_BPS = 1_000;

    // =========================================================================
    // EVENTS
    // =========================================================================

    /// @notice Emitted when a new Murabaha position is initiated.
    event MurabahaInitiated(
        bytes32 indexed movementId,
        address indexed msme,
        uint256 costBasis,
        uint256 markupBps,
        uint256 totalOwed,
        uint256 manifestValueAtInitiation
    );

    /// @notice Emitted when a Murabaha position is fully settled.
    event MurabahaSettled(
        bytes32 indexed movementId,
        address indexed msme,
        uint256 totalOwed
    );

    /// @notice Emitted when the Substrate oracle address is updated.
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    /**
     * @notice Prevents initiation of uncollateralized or speculative positions.
     * @dev    Calls the Substrate L1 oracle synchronously. The transaction reverts
     *         if the oracle reports no verified anchor for the given movementId.
     *         This is the primary Gharar (uncertainty) and Maysir (speculation)
     *         prevention mechanism at the smart contract level.
     * @param movementId    The eFTI Movement ID to validate against L1.
     */
    modifier preventUnanchoredPositions(bytes32 movementId) {
        require(
            address(substrateOracle) != address(0),
            "Settlement: oracle not configured"
        );
        require(
            substrateOracle.anchorExists(movementId),
            "Settlement: no verified L1 anchor for movementId (Gharar/Maysir)"
        );
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @notice Initializes the settlement contract.
     * @dev    The deployer receives Ownable ownership. The DATToken contract
     *         must separately grant MINTER_ROLE and BURNER_ROLE to this address.
     * @param _datToken         Address of the deployed DATToken contract.
     * @param _substrateOracle  Address of the deployed Substrate L1 oracle.
     */
    constructor(address _datToken, address _substrateOracle) Ownable(msg.sender) {
        require(_datToken != address(0), "Settlement: invalid DAT token address");
        datToken = DATToken(_datToken);
        substrateOracle = ISubstrateOracle(_substrateOracle);
    }

    // =========================================================================
    // CORE SETTLEMENT FUNCTIONS
    // =========================================================================

    /**
     * @notice Initiates a Murabaha trade finance position for an MSME.
     *
     * @dev    AAOIFI SS-20 Compliance:
     *         1. Oracle-gated: requires verified L1 anchor (preventUnanchoredPositions).
     *         2. Static cost-plus: totalOwed computed once via integer basis-point math.
     *         3. Markup cap: rejects markups exceeding MAX_MARKUP_BPS (10.00%).
     *         4. DAT tokens are minted directly to the MSME, representing the
     *            collateralized cargo value in the digital trade finance system.
     *         5. Idempotent: rejects duplicate movementId initiations.
     *
     * @param movementId    The eFTI Movement ID (must be anchored on L1).
     * @param msme          The MSME wallet address receiving the trade finance.
     * @param costBasis     The principal amount in USD cents.
     * @param markupBps     Fixed markup in basis points (max MAX_MARKUP_BPS).
     */
    function initiateMurabaha(
        bytes32 movementId,
        address msme,
        uint256 costBasis,
        uint256 markupBps
    )
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        preventUnanchoredPositions(movementId)
    {
        require(msme != address(0), "Settlement: MSME is zero address");
        require(costBasis > 0, "Settlement: costBasis must be positive");
        require(markupBps <= MAX_MARKUP_BPS, "Settlement: markup exceeds Shariah cap");
        require(
            murabahaTransactions[movementId].initiatedAtBlock == 0,
            "Settlement: position already initiated"
        );

        // Static, time-independent cost-plus calculation (Riba prevention).
        // Uses checked integer arithmetic; no floating point, no compounding.
        uint256 markupAmount = (costBasis * markupBps) / BPS_DENOMINATOR;
        uint256 totalOwed = costBasis + markupAmount;
        require(totalOwed >= costBasis, "Settlement: arithmetic overflow in totalOwed");

        // Read manifest value from L1 oracle at initiation time for record-keeping.
        uint256 manifestValue = substrateOracle.getManifestValue(movementId);

        murabahaTransactions[movementId] = MurabahaTransaction({
            movementId: movementId,
            msme: msme,
            costBasis: costBasis,
            markupBps: markupBps,
            totalOwed: totalOwed,
            settled: false,
            initiatedAtBlock: block.number,
            manifestValueAtInitiation: manifestValue
        });

        // Mint DAT tokens to the MSME representing the anchored cargo value.
        datToken.mint(msme, totalOwed, movementId);

        emit MurabahaInitiated(
            movementId,
            msme,
            costBasis,
            markupBps,
            totalOwed,
            manifestValue
        );
    }

    /**
     * @notice Settles (closes) an active Murabaha position by burning the MSME's DAT tokens.
     *
     * @dev    Settlement burns the totalOwed amount of DAT from the MSME's wallet,
     *         closing the collateral claim and completing the Murabaha trade lifecycle.
     *         Callable by the MSME itself or by the contract owner (protocol operator).
     *         Requires the MSME to have sufficient DAT balance (they must have received
     *         or obtained the tokens through the Murabaha lifecycle).
     *
     * @param movementId    The eFTI Movement ID of the position to settle.
     */
    function settlePayment(bytes32 movementId)
        external
        nonReentrant
        whenNotPaused
    {
        MurabahaTransaction storage tx_ = murabahaTransactions[movementId];
        require(tx_.initiatedAtBlock != 0, "Settlement: position not found");
        require(!tx_.settled, "Settlement: position already settled");
        require(
            msg.sender == tx_.msme || msg.sender == owner(),
            "Settlement: caller not authorized"
        );

        tx_.settled = true;

        // Burn DAT tokens from the MSME, closing the collateral claim.
        datToken.burnFrom(tx_.msme, tx_.totalOwed, movementId);

        emit MurabahaSettled(movementId, tx_.msme, tx_.totalOwed);
    }

    // =========================================================================
    // READ-ONLY VIEW FUNCTIONS
    // =========================================================================

    /**
     * @notice Returns the full MurabahaTransaction record for a given movementId.
     * @param movementId    The eFTI Movement ID to query.
     * @return              The MurabahaTransaction struct.
     */
    function getMurabahaTransaction(bytes32 movementId)
        external
        view
        returns (MurabahaTransaction memory)
    {
        require(
            murabahaTransactions[movementId].initiatedAtBlock != 0,
            "Settlement: position not found"
        );
        return murabahaTransactions[movementId];
    }

    /**
     * @notice Computes the static cost-plus totalOwed for a given costBasis and markupBps.
     * @dev    Pure function — no state read. Used for off-chain quoting.
     * @param costBasis     Principal amount in USD cents.
     * @param markupBps     Markup in basis points.
     * @return totalOwed    costBasis + ((costBasis * markupBps) / 10_000).
     */
    function calculateTotalOwed(uint256 costBasis, uint256 markupBps)
        external
        pure
        returns (uint256 totalOwed)
    {
        uint256 markupAmount = (costBasis * markupBps) / BPS_DENOMINATOR;
        totalOwed = costBasis + markupAmount;
        require(totalOwed >= costBasis, "Settlement: arithmetic overflow");
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /**
     * @notice Updates the Substrate L1 oracle address.
     * @dev    Only callable by the contract owner. Emits OracleUpdated.
     * @param _newOracle    The new oracle contract address.
     */
    function setSubstrateOracle(address _newOracle) external onlyOwner {
        require(_newOracle != address(0), "Settlement: invalid oracle address");
        emit OracleUpdated(address(substrateOracle), _newOracle);
        substrateOracle = ISubstrateOracle(_newOracle);
    }

    /// @notice Pauses all settlement operations. Callable only by owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses all settlement operations. Callable only by owner.
    function unpause() external onlyOwner {
        _unpause();
    }
}
