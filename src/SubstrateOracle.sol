// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISubstrateOracle} from "./DTLMFSettlement.sol";

/**
 * @title SubstrateOracle
 * @notice Canonical Substrate Layer 1 Oracle contract on Arbitrum AnyTrust L2.
 *         Relayer posts finalized L1 anchor statuses and manifest values here.
 */
contract SubstrateOracle is ISubstrateOracle, Ownable {
    mapping(bytes32 => bool) private _anchors;
    mapping(bytes32 => uint256) private _manifestValues;

    event AnchorSet(bytes32 indexed movementId, bool exists, uint256 manifestValue);

    constructor() Ownable(msg.sender) {}

    function setAnchor(bytes32 movementId, bool exists, uint256 manifestValue) external onlyOwner {
        _anchors[movementId] = exists;
        _manifestValues[movementId] = manifestValue;
        emit AnchorSet(movementId, exists, manifestValue);
    }

    function anchorExists(bytes32 movementId) external view override returns (bool) {
        return _anchors[movementId];
    }

    function getManifestValue(bytes32 movementId) external view override returns (uint256) {
        return _manifestValues[movementId];
    }
}
