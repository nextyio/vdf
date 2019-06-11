pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/math/Math.sol";

contract Unbiasable {

    // consensus variables
    uint256 maxSpeed;
    uint256 minSpeed;

    // The oldest the seed can be, any older data will be subjected to co-ordinated preimage attack.
    // This is just the lower bound recommendation of the protocol, user should choose a much higher value fo r better security against preimage attack.
    uint256 MinT0 = 4; // 2 blocks is 'just' enough to prevent a single sealer pre-image attack.

    // Minimum of verification time (in blocks). Give other verificator enough time to submit conflicted proof to nullify the challege.
    uint256 MinV = 60; // 2 minutes of block

    // Another minimum of verification time over the total T.
    uint256 vDividend = 1;
    uint256 vDivisor = 8;

    // r is the reduction rate of the rewards for each valid hash commited.
    // r = 1/2 is the neutral value where early evaluator re-commit doesn't give them any benefit, but also doesn't lose any rewards. This still allows Early Evaluator Griefing Attacks on later evaluators, smaller r value should be chosen for production.
    // uint256 rDividend = 1;
    // uint256 rDivisor = 2;

    constructor (
        uint256 _maxSpeed, // speed of the fatest evaluator (t/block)
        uint256 _minSpeed // speed of the fatest evaluator (t/block)
    )
        public
    {
        maxSpeed = _maxSpeed;
        minSpeed = _minSpeed;
    }

    struct Challenge {
        address maker;
        bytes32 entropy; // also treated as unique identification for each maker address
        uint256 C; // block number where the challenge is confirmed
        uint256 T; // challenge time
        uint256 Te; // evaluation time
        uint256 t; // iteration of the challenge
        Commit[] commits; // list of submitted proof commits
        bytes32 validProofHash; // the first valid proof hash
    }

    struct Commit {
        address evaluator;
        uint256 number;
        bytes32 proofCommit; // SHA256(evaluator+proof)
    }

    enum State {
        NONE,    // not a challenge
        EVAL,    // evaluation time
        VERIFY,  // out of evaluation time (Te)
        SUCCESS, // out of time (T) with one proof verified
        TIMEOUT, // out of time without any proof verified
        FAIL     // more than one valid proofs
    }

    // seed(address + entropy) => Challenge
    mapping(bytes32 => Challenge) challenges;

    // TODO: keep a list of challenges

    function challenge(
        bytes32 _entropy,
        uint256 _T
    )
        public
        returns (bytes32 seed)
    {
        require(_entropy != 0x0, "Must provide entropy.");
        seed = calcSeed(msg.sender, _entropy);
        require(challenges[seed].maker == address(0x0), "Duplicated challenge.");
        uint256 Tv = Math.max(_T * vDividend / vDivisor, MinV);
        uint256 Te = _T - Tv;

        // Workaround for challenges[seed] = Challenge({})
        challenges[seed].maker = msg.sender;
        challenges[seed].entropy = _entropy;
        challenges[seed].C = block.number;
        challenges[seed].T = _T;
        challenges[seed].Te = Te;
        challenges[seed].t = Te * minSpeed;

        return seed;
    }

    function calcSeed(
        address maker,
        bytes32 entropy
    )
        public
        pure
        returns (bytes32 seed)
    {
        return sha256(abi.encodePacked(maker, entropy));
    }

    function getIteration(
        bytes32 seed
    )
        public
        view
        returns (uint256)
    {
        return challenges[seed].t;
    }

    function state(
        Challenge storage c
    )
        internal
        view
        returns (State)
    {
        if (c.maker == address(0x0)) {
            return State.NONE;
        }
        if (c.entropy == 0x0) {
            return State.FAIL;
        }
        if (block.number < c.C + c.Te) {
            return State.EVAL;
        }
        if (block.number < c.C + c.T) {
            return State.VERIFY;
        }
        if (c.validProofHash == 0x0) {
            return State.TIMEOUT;
        }
        return State.SUCCESS;
    }

    function commit(
        bytes32 seed,
        bytes32 proofCommit
    )
        public
    {
        Challenge storage c = challenges[seed];
        require(c.maker != address(0x0), "No such challenge.");
        require(block.number <= c.C + c.Te, "Evaluation time is over.");
        require(c.validProofHash != 0x0, "Proof is already verified.");
        //require(state(c) == State.EVAL, "Not in evaluation phase.");
        Commit memory cm = Commit({
            evaluator: msg.sender,
            number: block.number,
            proofCommit: proofCommit
        });
        c.commits.push(cm);
    }

    function verify(
        bytes32[18] memory input // seed + t + proof[16]
    )
        public
        payable
        returns(bool valid)
    {
        bytes32 seed = input[0];
        Challenge storage c = challenges[seed];
        require(c.t == uint256(input[1]), "No such challenge.");
        // just hash the whole input for simplicity, technically only proof is needed here
        bytes32 proofHash = sha256(abi.encodePacked(input));
        require(c.validProofHash != proofHash, "Proof already verified.");
        assembly {
            // call vdfVerify precompile
            if iszero(call(not(0), 0xFF, 0, input, 576, valid, 1)) {
                revert(0, 0)
            }
        }
        if (!valid) {
            // not a valid proof
            return false;
        }
        if (c.validProofHash != 0x0) {
            // multiple valid proofs, ABORT!
            c.entropy = 0x0; // clear the entropy to signal an aborted challenge
            return false;
        }
        // record the first valid proof
        c.validProofHash = proofHash;
        return true;
    }

    function finalize(
        bytes32 seed
    )
        public
        returns (uint256[] memory numbers, address[] memory evaluators)
    {
        Challenge storage c = challenges[seed];
        require(state(c) == State.SUCCESS, "Challenge not success.");
        // Remove invalid commits
        for (uint i = 0; i<c.commits.length; ++i) {
            Commit storage cm = c.commits[i];
            bytes32 proofCommit = sha256(abi.encodePacked(cm.evaluator,c.validProofHash));
            if (proofCommit != cm.proofCommit) {
                // invalid commit
                c.commits[i] = c.commits[c.commits.length-1];
                c.commits.length--;
                continue;
            }
        }
        // Copy number and address to return
        numbers = new uint256[](c.commits.length);
        evaluators = new address[](c.commits.length);
        for (uint i = 0; i<c.commits.length; ++i) {
            Commit storage cm = c.commits[i];
            numbers[i] = cm.number;
            evaluators[i] = cm.evaluator;
        }
        return (numbers, evaluators);
    }
}