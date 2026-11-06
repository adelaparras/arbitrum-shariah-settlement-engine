// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Alejandro De La Parra Solomon / Solomon Brokerage OÜ (Republic of Estonia)
// All rights reserved. This design and synthesis are the intellectual property of the Author.
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SubstrateOracle} from "../src/SubstrateOracle.sol";
import {DATToken} from "../src/DATToken.sol";
import {DTLMFSettlement} from "../src/DTLMFSettlement.sol";
import {DTLMFMusharakahSettlement} from "../src/DTLMFMusharakahSettlement.sol";
import {DTLMFTakafulPool} from "../src/DTLMFTakafulPool.sol";
import {DTLMFSettlementInsurance} from "../src/DTLMFSettlementInsurance.sol";

contract DeployDTLMFScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) // Anvil default account 0
        );

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying DTLMF Shariah v1.8 Architecture with deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Substrate Oracle
        SubstrateOracle oracle = new SubstrateOracle();
        console.log("SubstrateOracle deployed at:", address(oracle));

        // 2. Deploy DATToken (ERC-20, Pausable, Burnable, Role-gated)
        DATToken datToken = new DATToken();
        console.log("DATToken deployed at:", address(datToken));

        // 3. Deploy DTLMFSettlement (Murabaha)
        DTLMFSettlement settlement = new DTLMFSettlement(address(datToken), address(oracle));
        console.log("DTLMFSettlement (Murabaha) deployed at:", address(settlement));

        // Grant MINTER_ROLE and BURNER_ROLE to DTLMFSettlement
        datToken.grantRole(datToken.MINTER_ROLE(), address(settlement));
        datToken.grantRole(datToken.BURNER_ROLE(), address(settlement));
        console.log("Granted MINTER_ROLE and BURNER_ROLE to DTLMFSettlement");

        // 4. Deploy DTLMFMusharakahSettlement (Partnership Pool)
        DTLMFMusharakahSettlement musharakah = new DTLMFMusharakahSettlement();
        console.log("DTLMFMusharakahSettlement deployed at:", address(musharakah));

        // 5. Deploy DTLMFTakafulPool (Mutual Cooperative Insurance)
        DTLMFTakafulPool takaful = new DTLMFTakafulPool(deployer);
        console.log("DTLMFTakafulPool deployed at:", address(takaful));

        // 6. Deploy DTLMFSettlementInsurance (Finality Escrow & Reorg Protection)
        DTLMFSettlementInsurance insurance = new DTLMFSettlementInsurance(
            address(datToken),
            address(oracle),
            deployer
        );
        console.log("DTLMFSettlementInsurance deployed at:", address(insurance));

        vm.stopBroadcast();

        console.log("\n=== DTLMF V1.8 DEPLOYMENT SUMMARY ===");
        console.log("SUBSTRATE_ORACLE_ADDRESS=", address(oracle));
        console.log("DAT_TOKEN_ADDRESS=", address(datToken));
        console.log("SETTLEMENT_ADDRESS=", address(settlement));
        console.log("MUSHARAKAH_ADDRESS=", address(musharakah));
        console.log("TAKAFUL_POOL_ADDRESS=", address(takaful));
        console.log("SETTLEMENT_INSURANCE_ADDRESS=", address(insurance));
    }
}
