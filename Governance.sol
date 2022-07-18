//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Storage {
    uint public myVal;
    address owner;
    event Stored(uint newVal);

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function makeOwner(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }

    function store(uint _newVal) external payable onlyOwner {
        myVal = _newVal;
        emit Stored(myVal);
    }

    function getBalance() external view returns(uint) {
        return address(this).balance;
    }
}





import "./ERC20Votes.sol";

contract MCSToken is ERC20Votes {
    constructor() ERC20("MCSToken", "MCT", 10000) {}
}





import "./ERC20.sol";

abstract contract ERC20Votes is ERC20 {
    function votingPower(address _of) public view returns(uint) {
        return balanceOf(_of);
    }
}




import "./ERC20Votes.sol";
import "./Lock.sol";

contract Govern {
    struct ProposalVote {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
        mapping(address => bool) hasVoted;
    }

    struct Proposal {
        uint votingStarts;
        uint votingEnds;
        bool executed;
        bool canceled;
    }

    enum ProposalState { Pending, Active, Succeeded, Defeated, Executed, Canceled }

    ERC20Votes public token;
    Timelock public timelock;
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => ProposalVote) public proposalVotes;
    uint public constant VOTING_DELAY = 5;
    uint public constant VOTING_DURATION = 60;

    event Executed(bytes32 proposalId, uint _timestamp);

    constructor(ERC20Votes _token, Timelock _lock) {
        token = _token;
        timelock = _lock;
    }

    function encode(uint _newVal) external pure returns(bytes memory) {
        return abi.encodePacked(_newVal);
    }

    function hash(string calldata _text) external pure returns(bytes32) {
        return keccak256(bytes(_text));
    }

    function propose( // 0x7416f4b1a83c12c1e5bce02c718e280a191477913aae6602ecb5dd0f1cce3cb8
        address _target,
        uint _value,
        string calldata _func,
        bytes calldata _data,
        string calldata _description
    ) external returns (bytes32 txId) {
        require(token.votingPower(msg.sender) > 1);

        txId = getTxId(_target, _value, _func, _data, keccak256(bytes(_description)));

        require(proposals[txId].votingStarts == 0);

        proposals[txId] = Proposal({
            votingStarts: block.timestamp + VOTING_DELAY,
            votingEnds: block.timestamp + VOTING_DELAY + VOTING_DURATION,
            executed: false,
            canceled: false
        });
    }

    function vote(bytes32 proposalId, uint8 voteType) external {
        require(
            state(proposalId) == ProposalState.Active
        );

        uint votingPower = token.votingPower(msg.sender);

        require(token.votingPower(msg.sender) > 1);

        ProposalVote storage proposal = proposalVotes[proposalId];

        require(!proposal.hasVoted[msg.sender]);

        if(voteType == 0) {
            proposal.againstVotes += votingPower;
        } else if(voteType == 1) {
            proposal.forVotes += votingPower;
        } else {
            proposal.abstainVotes += votingPower;
        }

        proposal.hasVoted[msg.sender] = true;
    }

    function execute(
        address _target,
        uint _value,
        string calldata _func,
        bytes calldata _data,
        bytes32 _descriptionHash
    ) external payable returns(bytes32 proposalId, uint timestamp) {
        require(msg.value == _value);

        proposalId = getTxId(_target, _value, _func, _data, _descriptionHash);

        require(state(proposalId) == ProposalState.Succeeded);

        Proposal storage proposal = proposals[proposalId];

        proposal.executed = true;

        timestamp = block.timestamp + 15;

        timelock.queue{value: msg.value}(
            _target,
            _value,
            _func,
            _data,
            timestamp
        );

        emit Executed(proposalId, timestamp);
    }

    function state(bytes32 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        ProposalVote storage proposalVote = proposalVotes[proposalId];

        require(proposal.votingStarts > 0);

        if (proposal.executed) {
            return ProposalState.Executed;
        }

        if (proposal.canceled) {
            return ProposalState.Canceled;
        }

        if(block.timestamp < proposal.votingStarts) {
            return ProposalState.Pending;
        }

        if(block.timestamp >= proposal.votingStarts && proposal.votingEnds > block.timestamp) {
            return ProposalState.Active;
        }

        if(proposalVote.forVotes > proposalVote.againstVotes) {
            return ProposalState.Succeeded;
        } else {
            return ProposalState.Defeated;
        }
    }

    function getTxId(
        address _target,
        uint _value,
        string calldata _func,
        bytes calldata _data,
        bytes32 _descriptionHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_target, _value, _func, _data, _descriptionHash));
    }
}



contract Timelock {
    error NotOwnerError();
    error AlreadyQueuedError(bytes32 txId);
    error TimestampNotInRangeError(uint blockTimestamp, uint timestamp);
    error NotQueuedError(bytes32 txId);
    error TimestampNotPassedError(uint blockTimestmap, uint timestamp);
    error TimestampExpiredError(uint blockTimestamp, uint expiresAt);
    error TxFailedError();

    event Queue(
        bytes32 indexed txId,
        address indexed target,
        uint value,
        string func,
        bytes data,
        uint timestamp
    );
    event Execute(
        bytes32 indexed txId,
        address indexed target,
        uint value,
        string func,
        bytes data,
        uint timestamp
    );
    event Cancel(bytes32 indexed txId);

    uint public constant MIN_DELAY = 10; // seconds
    uint public constant MAX_DELAY = 1000; // seconds
    uint public constant GRACE_PERIOD = 1000; // seconds

    address public owner;
    mapping(bytes32 => bool) public queued;

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwnerError();
        }
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function makeOwner(address _newOwner) external onlyOwner {
        owner = _newOwner;
    } // 1658142912

    function getTxId(
        address _target,
        uint _value,
        string calldata _func,
        bytes calldata _data,
        uint _timestamp
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(_target, _value, _func, _data, _timestamp));
    }

    function queue(
        address _target,
        uint _value,
        string calldata _func,
        bytes calldata _data,
        uint _timestamp
    ) external payable onlyOwner returns (bytes32 txId) {
        txId = getTxId(_target, _value, _func, _data, _timestamp);

        if (queued[txId]) {
            revert AlreadyQueuedError(txId);
        }

        if (
            _timestamp < block.timestamp + MIN_DELAY ||
            _timestamp > block.timestamp + MAX_DELAY
        ) {
            revert TimestampNotInRangeError(block.timestamp, _timestamp);
        }

        if (queued[txId]) {
            revert AlreadyQueuedError(txId);
        }

        queued[txId] = true;

        emit Queue(txId, _target, _value, _func, _data, _timestamp);
    }

    function execute(
        address _target,
        uint _value,
        string calldata _func,
        bytes calldata _data,
        uint _timestamp
    ) external payable returns (bytes memory) {
        bytes32 txId = getTxId(_target, _value, _func, _data, _timestamp);

        if (!queued[txId]) {
            revert NotQueuedError(txId);
        }

        if (block.timestamp < _timestamp) {
            revert TimestampNotPassedError(block.timestamp, _timestamp);
        }
        if (block.timestamp > _timestamp + GRACE_PERIOD) {
            revert TimestampExpiredError(block.timestamp, _timestamp + GRACE_PERIOD);
        }

        queued[txId] = false;

        // prepare data
        bytes memory data;
        if (bytes(_func).length > 0) {
            // data = func selector + _data
            data = abi.encodePacked(bytes4(keccak256(bytes(_func))), _data);
        } else {
            // call fallback with data
            data = _data;
        }

        // call target
        (bool ok, bytes memory res) = _target.call{value: _value}(data);
        if (!ok) {
            revert TxFailedError();
        }

        emit Execute(txId, _target, _value, _func, _data, _timestamp);

        return res;
    }

    function cancel(bytes32 _txId) external onlyOwner {
        if (!queued[_txId]) {
            revert NotQueuedError(_txId);
        }

        queued[_txId] = false;

        emit Cancel(_txId);
    }
}