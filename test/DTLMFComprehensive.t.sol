// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DATToken} from "../src/DATToken.sol";
import {DTLMFSettlement} from "../src/DTLMFSettlement.sol";
import {SubstrateOracle} from "../src/SubstrateOracle.sol";
import {DTLMFMusharakahSettlement} from "../src/DTLMFMusharakahSettlement.sol";
import {DTLMFTakafulPool} from "../src/DTLMFTakafulPool.sol";

contract DTLMFComprehensiveTest is Test {
    DATToken public datToken;
    SubstrateOracle public oracle;
    DTLMFSettlement public settlement;
    DTLMFMusharakahSettlement public musharakah;
    DTLMFTakafulPool public takafulPool;

    address public admin = address(this);
    address public msme = address(0x1111);
    address public financier = address(0x2222);
    address public unauthorized = address(0x3333);

    bytes32 public sampleMovement = bytes32(uint256(0xDEADBEEF1234));
    bytes32 public unanchoredMovement = bytes32(uint256(0xCAFEBABE5678));

    function setUp() public {
        // Deploy contracts
        datToken = new DATToken();
        oracle = new SubstrateOracle();
        settlement = new DTLMFSettlement(address(datToken), address(oracle));
        musharakah = new DTLMFMusharakahSettlement();
        takafulPool = new DTLMFTakafulPool(address(datToken));

        // Grant MINTER_ROLE and BURNER_ROLE to settlement contract
        datToken.grantRole(datToken.MINTER_ROLE(), address(settlement));
        datToken.grantRole(datToken.BURNER_ROLE(), address(settlement));
    }

    // =========================================================================
    // 1. AAOIFI SS-20: ORACLE GATING & GHARAR / MAYSIR PREVENTION
    // =========================================================================

    function test_RevertWhen_InitiateUnanchoredMurabaha() public {
        // Attempting to initiate Murabaha on an unanchored movementId must revert
        vm.expectRevert("Settlement: no verified L1 anchor for movementId (Gharar/Maysir)");
        settlement.initiateMurabaha(
            unanchoredMovement,
            msme,
            100_000 * 1e2, // $100,000 USD
            300 // 3.00% markup
        );
    }

    function test_SuccessfulMurabahaInitiationAndSettlement() public {
        // 1. Anchor cargo on L1 Oracle
        oracle.setAnchor(sampleMovement, true, 100_000 * 1e2);
        assertTrue(oracle.anchorExists(sampleMovement));

        // 2. Initiate Murabaha position: Cost basis $100,000, 300 bps (3%) markup
        uint256 costBasis = 100_000 * 1e2;
        uint256 markupBps = 300;
        uint256 expectedTotalOwed = costBasis + (costBasis * markupBps) / 10_000; // 103,000 * 1e2

        settlement.initiateMurabaha(
            sampleMovement,
            msme,
            costBasis,
            markupBps
        );

        // Verify position stored via mapping getter
        (
            bytes32 storedMovementId,
            address storedMsme,
            uint256 storedCostBasis,
            uint256 storedMarkupBps,
            uint256 storedTotalOwed,
            bool storedSettled,
            uint256 initiatedAtBlock,
            uint256 manifestValueAtInitiation
        ) = settlement.murabahaTransactions(sampleMovement);

        assertEq(storedMovementId, sampleMovement);
        assertEq(storedMsme, msme);
        assertEq(storedCostBasis, costBasis);
        assertEq(storedMarkupBps, markupBps);
        assertEq(storedTotalOwed, expectedTotalOwed);
        assertFalse(storedSettled);
        assertGt(initiatedAtBlock, 0);
        assertEq(manifestValueAtInitiation, 100_000 * 1e2);

        // Verify DAT Tokens were minted to MSME
        assertEq(datToken.balanceOf(msme), expectedTotalOwed);

        // 3. Prevent duplicate initiation (Idempotence & Maysir prevention)
        vm.expectRevert("Settlement: position already initiated");
        settlement.initiateMurabaha(
            sampleMovement,
            msme,
            costBasis,
            markupBps
        );

        // 4. Settle payment
        settlement.settlePayment(sampleMovement);

        // Verify tokens were burned and position is settled
        assertEq(datToken.balanceOf(msme), 0);
        (, , , , , bool settledAfter, , ) = settlement.murabahaTransactions(sampleMovement);
        assertTrue(settledAfter);
    }

    // =========================================================================
    // 2. AAOIFI SS-12: SHARIAH MARKUP CAP ENFORCEMENT (ANTI-RIBA)
    // =========================================================================

    function test_RevertWhen_MarkupExceedsShariahCap() public {
        oracle.setAnchor(sampleMovement, true, 50_000 * 1e2);

        // Maximum markup cap is 1000 bps (10.00%)
        vm.expectRevert("Settlement: markup exceeds Shariah cap");
        settlement.initiateMurabaha(
            sampleMovement,
            msme,
            50_000 * 1e2,
            1001 // Exceeds 1000 bps
        );
    }

    // =========================================================================
    // 3. ROLE ACCESS CONTROL (DAT TOKEN ISOLATION)
    // =========================================================================

    function test_RevertWhen_UnauthorizedMintsDAT() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        datToken.mint(unauthorized, 1000, sampleMovement);
    }

    function test_RevertWhen_UnauthorizedBurnsDAT() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        datToken.burnFrom(unauthorized, 1000, sampleMovement);
    }
}
