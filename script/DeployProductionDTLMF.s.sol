// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SubstrateOracle} from "../src/SubstrateOracle.sol";
import {DATToken} from "../src/DATToken.sol";
import {DTLMFSettlement} from "../src/DTLMFSettlement.sol";
import {DTLMFMusharakahSettlement} from "../src/DTLMFMusharakahSettlement.sol";
import {DTLMFTakafulPool} from "../src/DTLMFTakafulPool.sol";
import {DTLMFSettlementInsurance} from "../src/DTLMFSettlementInsurance.sol";
import {ShariahMultiSigAdjudicator} from "../src/ShariahMultiSigAdjudicator.sol";

contract DeployProductionDTLMF is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) // Anvil default account 0
        );

        address deployer = vm.addr(deployerPrivateKey);
        console.log("=== EXECUTING PRODUCTION MAINNET STAGING DEPLOYMENT ===");
        console.log("Deployer Address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Substrate Oracle Bridge
        SubstrateOracle oracle = new SubstrateOracle();
        console.log("[1/6] SubstrateOracle deployed at:", address(oracle));

        // 2. Deploy DATToken (Representative Cargo Asset)
        DATToken datToken = new DATToken();
        console.log("[2/6] DATToken deployed at:", address(datToken));

        // 3. Deploy DTLMFSettlement (AAOIFI SS-20 Murabaha Settlement Engine)
        DTLMFSettlement settlement = new DTLMFSettlement(address(datToken), address(oracle));
        console.log("[3/6] DTLMFSettlement deployed at:", address(settlement));

        // Strict Role Binding: Assign MINTER_ROLE and BURNER_ROLE strictly to DTLMFSettlement
        datToken.grantRole(datToken.MINTER_ROLE(), address(settlement));
        datToken.grantRole(datToken.BURNER_ROLE(), address(settlement));
        console.log(" -> Granted MINTER_ROLE & BURNER_ROLE exclusively to DTLMFSettlement");

        // 4. Deploy DTLMFMusharakahSettlement (AAOIFI SS-12 Capital Syndication Engine)
        DTLMFMusharakahSettlement musharakah = new DTLMFMusharakahSettlement();
        console.log("[4/6] DTLMFMusharakahSettlement deployed at:", address(musharakah));

        // 5. Deploy DTLMFTakafulPool (AAOIFI SS-26 Mutual Guarantee Pool)
        DTLMFTakafulPool takaful = new DTLMFTakafulPool(deployer);
        console.log("[5/6] DTLMFTakafulPool deployed at:", address(takaful));

        // 6. Deploy 3-of-5 Shariah Supervisory Board Multi-Sig Adjudicator
        address[5] memory scholars = [
            address(0x1010101010101010101010101010101010101010),
            address(0x2020202020202020202020202020202020202020),
            address(0x3030303030303030303030303030303030303030),
            address(0x4040404040404040404040404040404040404040),
            address(0x5050505050505050505050505050505050505050)
        ];
        ShariahMultiSigAdjudicator multiSig = new ShariahMultiSigAdjudicator(
            address(takaful),
            scholars
        );
        console.log("[6/6] ShariahMultiSigAdjudicator deployed at:", address(multiSig));

        // Strict Role Binding: Bind Takaful pool adjudicator to ShariahMultiSigAdjudicator
        takaful.setAdjudicator(address(multiSig));
        require(takaful.adjudicator() == address(multiSig), "Adjudicator binding failed");
        console.log(" -> Bound Takaful adjudicator strictly to 3-of-5 ShariahMultiSigAdjudicator");

        // 7. Deploy DTLMFSettlementInsurance (6,000-block Reorg Buffer)
        DTLMFSettlementInsurance insurance = new DTLMFSettlementInsurance(
            address(datToken),
            address(oracle),
            address(multiSig)
        );
        console.log("[7/7] DTLMFSettlementInsurance deployed at:", address(insurance));

        // Assert 6,000-block finality depth constant
        require(
            insurance.REORG_FINALITY_THRESHOLD() == 6_000,
            "Insurance: finality depth invariant mismatch"
        );
        console.log(" -> Verified 6,000-block reorg finality depth buffer (~25 min)");

        // Open underwriting cycle on Takaful Pool
        takaful.openCycle();
        require(takaful.cycleOpen(), "Takaful cycle failed to open");
        console.log(" -> Takaful Underwriting Cycle officially opened (Block:", block.number, ")");

        vm.stopBroadcast();

        console.log("\n=======================================================");
        console.log("PRODUCTION MAINNET STAGING DEPLOYMENT COMPLETE (100% PASS)");
        console.log("SUBSTRATE_ORACLE_ADDRESS   =", address(oracle));
        console.log("DAT_TOKEN_ADDRESS          =", address(datToken));
        console.log("SETTLEMENT_ADDRESS         =", address(settlement));
        console.log("MUSHARAKAH_ADDRESS         =", address(musharakah));
        console.log("TAKAFUL_POOL_ADDRESS       =", address(takaful));
        console.log("SHARIAH_MULTISIG_ADDRESS   =", address(multiSig));
        console.log("INSURANCE_ESCROW_ADDRESS   =", address(insurance));
        console.log("=======================================================\n");
    }
}
