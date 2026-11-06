// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
//
// Appendix XIV.B: DATToken.sol — Cargo-Collateralized Representative Asset
// Final Production Version 1.0 (V1.8 Shariah-Compliant)
//
// AAOIFI Compliance:
//   - Sukh al-Mal: 1:1 token representation of verified L1 cargo anchor value.
//   - AccessControl Isolation: MINTER_ROLE and BURNER_ROLE granted exclusively to
//     the settlement contract address, eliminating discretionary token expansion.
//   - No algorithmic rebasing, no fractional reserve issuance.

pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title DATToken
 * @notice DTLMF Anchor Token (DAT): A cargo-backed representative asset token.
 *
 * @dev Token issuance is strictly gated by MINTER_ROLE, which is exclusively
 *      granted to the DTLMFSettlement contract. This enforces the AAOIFI Sukh al-Mal
 *      principle: every DAT token in circulation represents a verified, on-chain
 *      anchored cargo position on Polkadot Layer 1.
 *
 *      Token destruction is gated by BURNER_ROLE, also granted exclusively to the
 *      settlement contract, ensuring burns only occur upon successful trade settlement.
 *
 *      The ERC20Pausable extension allows the DEFAULT_ADMIN_ROLE to freeze all
 *      transfers in the event of a regulatory or security incident (circuit breaker).
 */
contract DATToken is ERC20, ERC20Burnable, ERC20Pausable, AccessControl {

    // =========================================================================
    // ROLE DEFINITIONS
    // =========================================================================

    /// @notice Role exclusively held by the DTLMFSettlement contract.
    ///         Allows minting DAT tokens representing new anchored cargo positions.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role exclusively held by the DTLMFSettlement contract.
    ///         Allows burning DAT tokens upon trade settlement completion.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Role held by the protocol administrator (DAO or multisig).
    ///         Allows pausing all transfers as an emergency circuit breaker.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================================================================
    // EVENTS
    // =========================================================================

    /// @notice Emitted when a new DAT token batch is minted against a verified cargo anchor.
    /// @param to           Recipient address (MSME / Economic Operator wallet).
    /// @param amount       Amount of DAT minted (in token wei, 18 decimals).
    /// @param movementId   The eFTI Movement ID that backs this issuance.
    event DATMinted(address indexed to, uint256 amount, bytes32 indexed movementId);

    /// @notice Emitted when a DAT token batch is burned upon trade settlement.
    /// @param from         Address whose tokens are burned.
    /// @param amount       Amount of DAT burned (in token wei, 18 decimals).
    /// @param movementId   The eFTI Movement ID being closed.
    event DATBurned(address indexed from, uint256 amount, bytes32 indexed movementId);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @notice Initializes the DAT token with default admin assigned to the deployer.
     * @dev    The deployer receives DEFAULT_ADMIN_ROLE and PAUSER_ROLE.
     *         MINTER_ROLE and BURNER_ROLE are intentionally NOT granted at construction
     *         and must be explicitly assigned to the DTLMFSettlement contract address
     *         after deployment, preventing premature token issuance.
     */
    constructor() ERC20("DTLMF Anchor Token", "DAT") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // =========================================================================
    // MINTING — SETTLEMENT CONTRACT ONLY
    // =========================================================================

    /**
     * @notice Mints `amount` DAT tokens to `to`, backed by the given eFTI movement anchor.
     * @dev    Callable ONLY by the DTLMFSettlement contract (MINTER_ROLE).
     *         Each mint call must correspond to a verified L1 anchor on Polkadot.
     *         Fails if the contract is paused (regulatory circuit breaker).
     * @param to            Recipient address.
     * @param amount        Token amount (in wei, 18 decimal precision).
     * @param movementId    The eFTI Movement ID backing this issuance (for event indexing).
     */
    function mint(address to, uint256 amount, bytes32 movementId)
        external
        onlyRole(MINTER_ROLE)
        whenNotPaused
    {
        require(to != address(0), "DAT: mint to zero address");
        require(amount > 0, "DAT: mint amount must be positive");
        _mint(to, amount);
        emit DATMinted(to, amount, movementId);
    }

    // =========================================================================
    // BURNING — SETTLEMENT CONTRACT ONLY
    // =========================================================================

    /**
     * @notice Burns `amount` DAT tokens from `from`, closing the given eFTI movement.
     * @dev    Callable ONLY by the DTLMFSettlement contract (BURNER_ROLE).
     *         This is the settlement closure mechanism: burning tokens destroys the
     *         collateral claim, completing the Murabaha trade lifecycle.
     *         Does not require prior ERC20 approval — the settlement contract holds
     *         the BURNER_ROLE which grants direct burn authority.
     *         Fails if the contract is paused.
     * @param from          Address to burn tokens from.
     * @param amount        Token amount (in wei, 18 decimal precision).
     * @param movementId    The eFTI Movement ID being closed (for event indexing).
     */
    function burnFrom(address from, uint256 amount, bytes32 movementId)
        external
        onlyRole(BURNER_ROLE)
        whenNotPaused
    {
        require(from != address(0), "DAT: burn from zero address");
        require(amount > 0, "DAT: burn amount must be positive");
        _burn(from, amount);
        emit DATBurned(from, amount, movementId);
    }

    // =========================================================================
    // CIRCUIT BREAKER (EMERGENCY)
    // =========================================================================

    /// @notice Pauses all DAT token transfers. Callable only by PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses all DAT token transfers. Callable only by PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // REQUIRED OVERRIDE RESOLUTION
    // =========================================================================

    /**
     * @dev Resolves the diamond inheritance conflict between ERC20 and ERC20Pausable.
     *      Both parent contracts override _update; this function explicitly calls
     *      ERC20Pausable's version, which internally delegates to ERC20._update,
     *      ensuring the pause check is enforced on every transfer/mint/burn.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}
