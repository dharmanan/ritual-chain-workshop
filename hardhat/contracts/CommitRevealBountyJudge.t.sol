// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealBountyJudge} from "./CommitRevealBountyJudge.sol";

/// @dev Mock that stands in for the Ritual LLM inference precompile (0x0802)
///      and always returns a successful completion. The short-running async
///      precompile ABI is: abi.encode(bytes simmedInput, bytes actualOutput),
///      where actualOutput is
///      abi.encode(bool hasError, bytes completion, bytes raw, string err, ConvoHistory).
contract MockLLMOk {
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory actualOutput = abi.encode(
            false, // hasError
            bytes("Winner: Submission #0 best matches the rubric."), // completion
            bytes(""), // raw
            "", // errorMessage
            ConvoHistory("", "", "")
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

/// @dev Mock precompile that reports a model-side error.
contract MockLLMError {
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory actualOutput = abi.encode(
            true, // hasError
            bytes(""),
            bytes(""),
            "model overloaded",
            ConvoHistory("", "", "")
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

contract CommitRevealBountyJudgeTest is Test {
    CommitRevealBountyJudge internal judge;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    address internal constant LLM = address(0x0802);

    uint256 internal commitDeadline;
    uint256 internal revealDeadline;

    function setUp() public {
        judge = new CommitRevealBountyJudge();
        commitDeadline = block.timestamp + 1 days;
        revealDeadline = block.timestamp + 2 days;
        vm.deal(owner, 100 ether);
    }

    // ----------------------------- helpers ------------------------------ //

    function _createBounty() internal returns (uint256 id) {
        vm.prank(owner);
        id = judge.createBounty{value: 1 ether}(
            "Best haiku",
            "Most evocative, 5-7-5",
            commitDeadline,
            revealDeadline
        );
    }

    function _commit(
        uint256 id,
        address who,
        string memory answer,
        bytes32 salt
    ) internal {
        bytes32 c = keccak256(abi.encodePacked(answer, salt, who, id));
        vm.prank(who);
        judge.submitCommitment(id, c);
    }

    function _installOkPrecompile() internal {
        MockLLMOk mock = new MockLLMOk();
        vm.etch(LLM, address(mock).code);
    }

    function _installErrorPrecompile() internal {
        MockLLMError mock = new MockLLMError();
        vm.etch(LLM, address(mock).code);
    }

    // ------------------------- happy path ------------------------------- //

    function test_FullFlow_CommitRevealJudgeFinalize() public {
        uint256 id = _createBounty();

        bytes32 saltA = keccak256("a");
        bytes32 saltB = keccak256("b");
        _commit(id, alice, "old pond / frog leaps in", saltA);
        _commit(id, bob, "spring rain falls soft", saltB);

        // Move into reveal window.
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "old pond / frog leaps in", saltA);
        vm.prank(bob);
        judge.revealAnswer(id, "spring rain falls soft", saltB);

        // Move past reveal window and judge.
        vm.warp(revealDeadline + 1);
        _installOkPrecompile();
        vm.prank(owner);
        judge.judgeAll(id, hex"1234");

        (bool judged, , , , uint256 subCount, , bytes memory review) =
            judge.getBountyState(id);
        assertTrue(judged, "should be judged");
        assertEq(subCount, 2, "two revealed submissions");
        assertGt(review.length, 0, "review stored");

        uint256 aliceBefore = alice.balance;
        vm.prank(owner);
        judge.finalizeWinner(id, 0);
        assertEq(alice.balance, aliceBefore + 1 ether, "winner paid");
    }

    // --------------------------- commit phase --------------------------- //

    function test_RevertWhen_CommitAfterDeadline() public {
        uint256 id = _createBounty();
        vm.warp(commitDeadline + 1);
        bytes32 c = keccak256(abi.encode(alice, "x", bytes32("s")));
        vm.prank(alice);
        vm.expectRevert(bytes("commit window closed"));
        judge.submitCommitment(id, c);
    }

    function test_RevertWhen_DoubleCommit() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        bytes32 c = keccak256(abi.encode(alice, "y", bytes32("s2")));
        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        judge.submitCommitment(id, c);
    }

    // --------------------------- reveal phase --------------------------- //

    function test_RevertWhen_RevealBeforeWindow() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.prank(alice);
        vm.expectRevert(bytes("reveal not open"));
        judge.revealAnswer(id, "x", bytes32("s"));
    }

    function test_RevertWhen_RevealWrongSalt() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(id, "x", bytes32("WRONG"));
    }

    function test_RevertWhen_RevealWrongAnswer() public {
        uint256 id = _createBounty();
        _commit(id, alice, "real answer", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(id, "fake answer", bytes32("s"));
    }

    function test_RevertWhen_CopycatRevealsStolenPair() public {
        // alice commits + reveals; bob never committed and tries to claim
        // alice's (answer, salt) — must fail because the hash binds the address.
        uint256 id = _createBounty();
        _commit(id, alice, "winning answer", bytes32("salt"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "winning answer", bytes32("salt"));

        vm.prank(bob);
        vm.expectRevert(bytes("no commitment"));
        judge.revealAnswer(id, "winning answer", bytes32("salt"));
    }

    function test_RevertWhen_DoubleReveal() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "x", bytes32("s"));
        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        judge.revealAnswer(id, "x", bytes32("s"));
    }

    function test_RevertWhen_RevealAfterWindow() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(revealDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("reveal window closed"));
        judge.revealAnswer(id, "x", bytes32("s"));
    }

    // ---------------------------- judge phase --------------------------- //

    function test_RevertWhen_JudgeBeforeRevealClosed() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "x", bytes32("s"));
        _installOkPrecompile();
        vm.prank(owner);
        vm.expectRevert(bytes("reveal still open"));
        judge.judgeAll(id, hex"00");
    }

    function test_RevertWhen_JudgeNotOwner() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "x", bytes32("s"));
        vm.warp(revealDeadline + 1);
        _installOkPrecompile();
        vm.prank(bob);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(id, hex"00");
    }

    function test_RevertWhen_LLMReportsError() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "x", bytes32("s"));
        vm.warp(revealDeadline + 1);
        _installErrorPrecompile();
        vm.prank(owner);
        vm.expectRevert(bytes("model overloaded"));
        judge.judgeAll(id, hex"00");
    }

    // --------------------------- finalize ------------------------------- //

    function test_RevertWhen_FinalizeBeforeJudge() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "x", bytes32("s"));
        vm.warp(revealDeadline + 1);
        vm.prank(owner);
        vm.expectRevert(bytes("not judged yet"));
        judge.finalizeWinner(id, 0);
    }

    function test_RevertWhen_FinalizeBadIndex() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s"));
        vm.warp(commitDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(id, "x", bytes32("s"));
        vm.warp(revealDeadline + 1);
        _installOkPrecompile();
        vm.prank(owner);
        judge.judgeAll(id, hex"00");
        vm.prank(owner);
        vm.expectRevert(bytes("invalid winner index"));
        judge.finalizeWinner(id, 5);
    }

    // ----------------------------- cancel ------------------------------- //

    function test_CancelRefundsWhenNoReveals() public {
        uint256 id = _createBounty();
        _commit(id, alice, "x", bytes32("s")); // committed but never revealed
        vm.warp(revealDeadline + 1);
        uint256 before = owner.balance;
        vm.prank(owner);
        judge.cancelBounty(id);
        assertEq(owner.balance, before + 1 ether, "owner refunded");
    }

    // ----------------------- view parity check -------------------------- //

    function test_ComputeCommitmentMatchesOnChain() public view {
        bytes32 expected = keccak256(
            abi.encodePacked("hello", bytes32("s"), alice, uint256(1))
        );
        assertEq(
            judge.computeCommitment(1, "hello", bytes32("s"), alice),
            expected
        );
    }
}
