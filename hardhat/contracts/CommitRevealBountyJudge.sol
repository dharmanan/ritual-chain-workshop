// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @notice Minimal interface for the Ritual wallet that funds precompile usage.
interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

/// @title CommitRevealBountyJudge
/// @notice Privacy-preserving bounty judge for Ritual Chain.
/// @dev Submissions are kept secret on-chain during the contest using a
///      commit-reveal scheme, then judged by the Ritual LLM inference
///      precompile (0x0802) once every entry is locked in. This prevents
///      copycats from reading a rival's answer out of public calldata and
///      front-running it with a better paraphrase before the deadline.
///
/// Lifecycle of a bounty:
///   create -> [commit window] -> [reveal window] -> judge -> finalize
///
///   1. createBounty            owner funds the reward, sets both deadlines
///   2. submitCommitment        entrants post keccak256 hashes (answers hidden)
///   3. revealAnswer            entrants disclose answer + salt; hash is checked
///   4. judgeAll                owner runs the LLM judge over revealed answers
///   5. finalizeWinner          owner pays the chosen submission's author
contract CommitRevealBountyJudge is PrecompileConsumer {
    // --------------------------------------------------------------------- //
    //                               Constants                               //
    // --------------------------------------------------------------------- //

    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    /// @dev On Ritual mainnet the LLM precompile is paid for out of a wallet
    ///      deposit. Kept here so the deployment can be funded; not used in
    ///      the local mock tests.
    IRitualWallet public constant WALLET =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // --------------------------------------------------------------------- //
    //                                Storage                                //
    // --------------------------------------------------------------------- //

    uint256 public nextBountyId = 1;

    /// @dev A single entrant's hidden commitment for a bounty.
    struct Commitment {
        bytes32 hash; // keccak256(abi.encodePacked(answer, salt, committer, bountyId))
        bool exists;
        bool revealed;
    }

    /// @dev A revealed answer, in the canonical order used by the LLM judge
    ///      and by finalizeWinner's winnerIndex.
    struct Submission {
        address submitter;
        string answer;
    }

    /// @dev Decode shape returned by the Ritual LLM inference precompile.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 commitDeadline; // commits accepted while now < commitDeadline
        uint256 revealDeadline; // reveals accepted while now < revealDeadline
        bool judged;
        bool finalized;
        bool cancelled;
        bytes aiReview; // raw LLM output stored for transparency
        uint256 winnerIndex;
        uint256 commitmentCount;
        Submission[] submissions; // revealed answers only
    }

    mapping(uint256 => Bounty) private _bounties;

    /// @dev bountyId => committer => commitment
    mapping(uint256 => mapping(address => Commitment)) private _commitments;

    /// @dev Simple reentrancy guard for the payout path.
    uint256 private _locked = 1;

    // --------------------------------------------------------------------- //
    //                                 Events                                //
    // --------------------------------------------------------------------- //

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 commitDeadline,
        uint256 revealDeadline
    );
    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed committer,
        bytes32 commitment
    );
    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );
    event BountyCancelled(uint256 indexed bountyId, uint256 refund);

    // --------------------------------------------------------------------- //
    //                               Modifiers                               //
    // --------------------------------------------------------------------- //

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == _bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(_bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    // --------------------------------------------------------------------- //
    //                            Bounty creation                            //
    // --------------------------------------------------------------------- //

    /// @notice Create and fund a bounty.
    /// @param title          Human-readable name.
    /// @param rubric         Judging criteria the LLM should grade against.
    /// @param commitDeadline Unix time after which no new commitments accepted.
    /// @param revealDeadline Unix time after which no reveals accepted; must be
    ///                       strictly greater than commitDeadline.
    /// @return bountyId      The id of the freshly created bounty.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 commitDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(commitDeadline > block.timestamp, "commit deadline in past");
        require(revealDeadline > commitDeadline, "reveal must follow commit");

        bountyId = nextBountyId++;

        Bounty storage b = _bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.commitDeadline = commitDeadline;
        b.revealDeadline = revealDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            commitDeadline,
            revealDeadline
        );
    }

    // --------------------------------------------------------------------- //
    //                            Commit phase                               //
    // --------------------------------------------------------------------- //

    /// @notice Post a hidden commitment to an answer.
    /// @dev The commitment must equal
    ///      keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
    ///      Binding msg.sender stops anyone from re-using a revealed
    ///      (answer, salt) pair as their own late commitment; binding bountyId
    ///      stops a commitment from being replayed across different bounties.
    /// @param bountyId   Target bounty.
    /// @param commitment The keccak256 hash described above.
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp < b.commitDeadline, "commit window closed");
        require(commitment != bytes32(0), "empty commitment");
        require(
            b.commitmentCount < MAX_SUBMISSIONS,
            "too many commitments"
        );

        Commitment storage c = _commitments[bountyId][msg.sender];
        require(!c.exists, "already committed");

        c.hash = commitment;
        c.exists = true;
        b.commitmentCount++;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    // --------------------------------------------------------------------- //
    //                            Reveal phase                               //
    // --------------------------------------------------------------------- //

    /// @notice Reveal a previously committed answer.
    /// @dev Verifies keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
    ///      matches the stored commitment, then records the answer in the
    ///      canonical submissions array.
    /// @param bountyId Target bounty.
    /// @param answer   The plaintext answer.
    /// @param salt     The random salt used at commit time.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp >= b.commitDeadline, "reveal not open");
        require(block.timestamp < b.revealDeadline, "reveal window closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        Commitment storage c = _commitments[bountyId][msg.sender];
        require(c.exists, "no commitment");
        require(!c.revealed, "already revealed");

        bytes32 check = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
        require(check == c.hash, "commitment mismatch");

        c.revealed = true;

        b.submissions.push(Submission({submitter: msg.sender, answer: answer}));
        uint256 index = b.submissions.length - 1;

        emit AnswerRevealed(bountyId, index, msg.sender);
    }

    // --------------------------------------------------------------------- //
    //                             Judge phase                               //
    // --------------------------------------------------------------------- //

    /// @notice Run the Ritual LLM judge over all revealed answers.
    /// @dev Callable only after the reveal window has closed so the answer set
    ///      is final. The owner builds `llmInput` off-chain from the rubric and
    ///      the canonical answers returned by {assembleAnswers}; anyone can
    ///      recompute that view to audit the request.
    /// @param bountyId Target bounty.
    /// @param llmInput ABI-encoded request for the LLM inference precompile.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp >= b.revealDeadline, "reveal still open");
        require(!b.judged, "already judged");
        require(!b.finalized, "already finalized");
        require(!b.cancelled, "cancelled");
        require(b.submissions.length > 0, "no revealed submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        b.judged = true;
        b.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    // --------------------------------------------------------------------- //
    //                           Finalize / payout                           //
    // --------------------------------------------------------------------- //

    /// @notice Pay the reward to the author of the winning submission.
    /// @param bountyId    Target bounty.
    /// @param winnerIndex Index into the revealed submissions array.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = _bounties[bountyId];

        require(b.judged, "not judged yet");
        require(!b.finalized, "already finalized");
        require(winnerIndex < b.submissions.length, "invalid winner index");

        b.finalized = true;
        b.winnerIndex = winnerIndex;

        address winner = b.submissions[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    /// @notice Refund the reward to the owner if a bounty produced no revealed
    ///         answers by the reveal deadline.
    /// @param bountyId Target bounty.
    function cancelBounty(
        uint256 bountyId
    ) external bountyExists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = _bounties[bountyId];

        require(block.timestamp >= b.revealDeadline, "reveal still open");
        require(b.submissions.length == 0, "has submissions");
        require(!b.finalized, "already finalized");
        require(!b.cancelled, "already cancelled");

        b.cancelled = true;
        uint256 refund = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(b.owner).call{value: refund}("");
        require(ok, "refund failed");

        emit BountyCancelled(bountyId, refund);
    }

    // --------------------------------------------------------------------- //
    //                                Views                                  //
    // --------------------------------------------------------------------- //

    /// @notice Canonical, auditable rendering of every revealed answer.
    /// @dev The owner should embed exactly this text in the LLM judge prompt.
    ///      Because it is deterministic, any third party can recompute it and
    ///      compare against the `llmInput` used in {judgeAll}.
    function assembleAnswers(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (string memory out) {
        Bounty storage b = _bounties[bountyId];
        for (uint256 i = 0; i < b.submissions.length; i++) {
            out = string.concat(
                out,
                "### Submission #",
                _toString(i),
                "\n",
                b.submissions[i].answer,
                "\n\n"
            );
        }
    }

    /// @notice Returns the descriptive fields of a bounty.
    function getBountyInfo(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 commitDeadline,
            uint256 revealDeadline
        )
    {
        Bounty storage b = _bounties[bountyId];
        return (
            b.owner,
            b.title,
            b.rubric,
            b.reward,
            b.commitDeadline,
            b.revealDeadline
        );
    }

    /// @notice Returns the state / progress fields of a bounty.
    function getBountyState(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            bool judged,
            bool finalized,
            bool cancelled,
            uint256 commitmentCount,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage b = _bounties[bountyId];
        return (
            b.judged,
            b.finalized,
            b.cancelled,
            b.commitmentCount,
            b.submissions.length,
            b.winnerIndex,
            b.aiReview
        );
    }

    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage b = _bounties[bountyId];
        require(index < b.submissions.length, "invalid index");
        Submission storage s = b.submissions[index];
        return (s.submitter, s.answer);
    }

    function getCommitment(
        uint256 bountyId,
        address committer
    )
        external
        view
        bountyExists(bountyId)
        returns (bytes32 hash, bool exists, bool revealed)
    {
        Commitment storage c = _commitments[bountyId][committer];
        return (c.hash, c.exists, c.revealed);
    }

    /// @notice Off-chain helper mirror of the on-chain commitment formula.
    /// @dev Pure convenience so a front-end can sanity-check its hashing.
    function computeCommitment(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt,
        address committer
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, committer, bountyId));
    }

    // --------------------------------------------------------------------- //
    //                               Internal                                //
    // --------------------------------------------------------------------- //

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
