// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DTLMFTakafulPool} from "../src/DTLMFTakafulPool.sol";
import {ShariahMultiSigAdjudicator} from "../src/ShariahMultiSigAdjudicator.sol";

contract ShariahMultiSigTest is Test {
    DTLMFTakafulPool public pool;
    ShariahMultiSigAdjudicator public multiSig;

    address public admin = address(this);
    address public operator = address(0xAA);
    address public claimant = address(0xBB);

    address public scholar1 = address(0x101);
    address public scholar2 = address(0x102);
    address public scholar3 = address(0x103);
    address public scholar4 = address(0x104);
    address public scholar5 = address(0x105);
    address public unauthorized = address(0x999);

    bytes32 public movementId = keccak256("MOVE-2026-PILOT-001");

    receive() external payable {}

    function setUp() public {
        address[5] memory scholars = [scholar1, scholar2, scholar3, scholar4, scholar5];

        // 1. Deploy Takaful pool initially with temporary address
        pool = new DTLMFTakafulPool(admin);

        // 2. Deploy Shariah Multi-Sig with pool reference and 5 scholars
        multiSig = new ShariahMultiSigAdjudicator(address(pool), scholars);

        // 3. Set pool adjudicator to Multi-Sig address
        pool.setAdjudicator(address(multiSig));
        assertEq(pool.adjudicator(), address(multiSig));

        // 4. Open pool cycle and contribute initial liquidity
        pool.openCycle();
        vm.deal(claimant, 10 ether);

        vm.prank(claimant);
        pool.contributePremium{value: 5 ether}(claimant);

        assertEq(pool.participantPoolBalance(), 4.5 ether);
        assertEq(pool.operatorVaultBalance(), 0.5 ether);
    }

    function test_3Of5MultiSigAdjudicationLifecycle() public {
        // Claimant files a valid loss claim of 1.0 ETH (within 50% cap of 4.5 ETH)
        vm.prank(claimant);
        uint256 claimId = pool.fileLossClaim(movementId, 1 ether, "ipfs://QmLossEvidence001");
        assertEq(claimId, 0);

        bytes32 fatwaHash = keccak256("FATWA-SSB-2026-CLAIM-001-APPROVED");

        // Attempt by unauthorized party to propose must revert
        vm.prank(unauthorized);
        vm.expectRevert("ShariahMultiSig: caller is not a Shariah scholar");
        multiSig.proposeAdjudication(claimId, true, fatwaHash);

        // 1. Scholar 1 proposes approval
        vm.prank(scholar1);
        uint256 proposalId = multiSig.proposeAdjudication(claimId, true, fatwaHash);
        assertEq(proposalId, 0);

        // Check proposal state (1 vote, not executed)
        (uint256 propClaimId, bool propApprove, uint256 propVotes, bool propExecuted, ) = multiSig.proposals(proposalId);
        assertEq(propClaimId, claimId);
        assertTrue(propApprove);
        assertEq(propVotes, 1);
        assertFalse(propExecuted);

        // Scholar 1 cannot vote again (duplicate vote prevention)
        vm.prank(scholar1);
        vm.expectRevert("ShariahMultiSig: scholar already voted");
        multiSig.confirmAdjudication(proposalId);

        // 2. Scholar 2 confirms (2 votes, still not executed)
        vm.prank(scholar2);
        multiSig.confirmAdjudication(proposalId);

        (, , propVotes, propExecuted, ) = multiSig.proposals(proposalId);
        assertEq(propVotes, 2);
        assertFalse(propExecuted);

        // Verify pool balance unchanged yet
        assertEq(pool.participantPoolBalance(), 4.5 ether);

        // 3. Scholar 3 confirms (3 votes -> QUORUM REACHED -> AUTO-EXECUTED!)
        uint256 claimantBalanceBefore = claimant.balance;

        vm.prank(scholar3);
        multiSig.confirmAdjudication(proposalId);

        // Verify executed
        (, , propVotes, propExecuted, ) = multiSig.proposals(proposalId);
        assertEq(propVotes, 3);
        assertTrue(propExecuted);

        // Verify payout made to claimant (1.0 ETH paid)
        assertEq(claimant.balance, claimantBalanceBefore + 1 ether);
        assertEq(pool.participantPoolBalance(), 3.5 ether);

        // 4. Scholar 4 attempting to vote on already executed proposal reverts
        vm.prank(scholar4);
        vm.expectRevert("ShariahMultiSig: proposal already executed");
        multiSig.confirmAdjudication(proposalId);
    }

    // =========================================================================
    // STAGE 6.2: ANNUAL CYCLE CLOSE & SURPLUS DISTRIBUTION (ZERO OPERATOR CAPTURE)
    // =========================================================================

    function test_AnnualCycleSurplusDistributionWithZeroOperatorCapture() public {
        address alice = address(0xA1);
        address bob = address(0xB2);
        address charlie = address(0xC3);

        vm.deal(alice, 20 ether);
        vm.deal(bob, 20 ether);
        vm.deal(charlie, 20 ether);

        // Re-deploy a fresh pool and multisig for cycle simulation
        address[5] memory scholars = [scholar1, scholar2, scholar3, scholar4, scholar5];
        DTLMFTakafulPool freshPool = new DTLMFTakafulPool(admin);
        ShariahMultiSigAdjudicator freshMultiSig = new ShariahMultiSigAdjudicator(address(freshPool), scholars);
        freshPool.setAdjudicator(address(freshMultiSig));
        freshPool.openCycle();

        // 1. Economic Operators contribute premiums:
        // Alice: 10 ETH (9.0 ETH Amanah, 1.0 ETH Wakala fee)
        vm.prank(alice);
        freshPool.contributePremium{value: 10 ether}(alice);

        // Bob: 6 ETH (5.4 ETH Amanah, 0.6 ETH Wakala fee)
        vm.prank(bob);
        freshPool.contributePremium{value: 6 ether}(bob);

        // Charlie: 4 ETH (3.6 ETH Amanah, 0.4 ETH Wakala fee)
        vm.prank(charlie);
        freshPool.contributePremium{value: 4 ether}(charlie);

        // Total gross: 20 ETH -> 18 ETH Amanah pool, 2 ETH operator vault
        assertEq(freshPool.participantPoolBalance(), 18 ether);
        assertEq(freshPool.operatorVaultBalance(), 2 ether);

        // 2. Bob files a loss claim of 3.0 ETH
        bytes32 cargoDocHash = keccak256("DOC-2026-NORDIC-CORRIDOR-LOSS-CLAIM");
        vm.prank(bob);
        uint256 bobClaimId = freshPool.fileLossClaim(cargoDocHash, 3 ether, "ipfs://QmVerifiedDamageProof");

        // 3. 3-of-5 Scholar multi-sig review & sign-off
        bytes32 fatwa = keccak256("FATWA-SSB-2026-CLAIM-ADJUDICATION-002");
        vm.prank(scholar1);
        uint256 propId = freshMultiSig.proposeAdjudication(bobClaimId, true, fatwa);

        vm.prank(scholar3);
        freshMultiSig.confirmAdjudication(propId);

        uint256 bobBalBefore = bob.balance;
        vm.prank(scholar5); // 3rd scholar vote -> triggers execution
        freshMultiSig.confirmAdjudication(propId);

        // Verify Bob received 3.0 ETH claim disbursement
        assertEq(bob.balance, bobBalBefore + 3 ether);
        assertEq(freshPool.participantPoolBalance(), 15 ether);

        // 4. Annual Cycle Close Simulation
        freshPool.closeCycle();
        assertFalse(freshPool.cycleOpen());

        // Snapshot balances before surplus distribution
        uint256 aliceBalBefore = alice.balance;
        bobBalBefore = bob.balance;
        uint256 charlieBalBefore = charlie.balance;

        // 5. Invoke distributePoolSurplus()
        // Remaining surplus: 15.0 ETH
        // Pro-rata shares based on Amanah contributions (9 : 5.4 : 3.6, total 18.0):
        // Alice   : 9.0 / 18.0 = 50%  -> 7.5 ETH
        // Bob     : 5.4 / 18.0 = 30%  -> 4.5 ETH
        // Charlie : 3.6 / 18.0 = 20%  -> 3.0 ETH
        freshPool.distributePoolSurplus();

        assertEq(alice.balance, aliceBalBefore + 7.5 ether);
        assertEq(bob.balance, bobBalBefore + 4.5 ether);
        assertEq(charlie.balance, charlieBalBefore + 3.0 ether);

        // Verify participantPoolBalance is completely cleared (0)
        assertEq(freshPool.participantPoolBalance(), 0);

        // Verify zero operator capture: operator vault is untouched (2.0 ETH)
        assertEq(freshPool.operatorVaultBalance(), 2 ether);

        // 6. Operator withdraws their earned Wakala fee (2.0 ETH)
        freshPool.withdrawWakalaFees(2 ether);
        assertEq(freshPool.operatorVaultBalance(), 0);
        assertEq(address(freshPool).balance, 0);
    }
}

