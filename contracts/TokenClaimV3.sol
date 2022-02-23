// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library MerkleProof {
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    function processProof(bytes32[] memory proof, bytes32 leaf)
        internal
        pure
        returns (bytes32)
    {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                // Hash(current computed hash + current element of the proof)
                computedHash = _efficientHash(computedHash, proofElement);
            } else {
                // Hash(current element of the proof + current computed hash)
                computedHash = _efficientHash(proofElement, computedHash);
            }
        }
        return computedHash;
    }

    function _efficientHash(bytes32 a, bytes32 b)
        private
        pure
        returns (bytes32 value)
    {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        _transferOwnership(_msgSender());
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

library SafeERC20 {
    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        require(token.transfer(to, value), "SafeERC20: Transfer failed");
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        require(
            token.transferFrom(from, to, value),
            "SafeERC20: Transfer from failed"
        );
    }
}

contract TokenClaim is Ownable {
    using SafeERC20 for IERC20;

    uint256 public noOfVestings;
    IERC20 public immutable ERC20Interface;

    struct Vesting {
        bytes32 rootHash;
        uint256 startTime;
        uint256 phaseRewardTotal;
        uint256 phaseRewardBalance;
    }

    mapping(uint256 => bool) public paused;
    mapping(uint256 => Vesting) public vestingDetail;
    mapping(address => mapping(uint256 => bool)) public hasClaimed;

    event Claimed(
        address indexed user,
        uint256 indexed phaseNo,
        uint256 amount
    );

    constructor(
        bytes32[] memory _rootHash,
        uint256[] memory _startTimes,
        uint256[] memory _phaseRewardTotal,
        address _token
    ) {
        uint256 len = _rootHash.length;
        require(len > 0, "No single entry");
        require(
            len == _startTimes.length && _phaseRewardTotal.length == len,
            "Length mismatch"
        );
        require(_token != address(0), "Zero token address");

        for (uint256 i = 0; i < len; i++) {
            require(
                addVesting(_rootHash[i], _startTimes[i], _phaseRewardTotal[i])
            );
        }
        ERC20Interface = IERC20(_token);
    }

    function addVesting(
        bytes32 _rootHash,
        uint256 _startTime,
        uint256 _phaseRewardTotal
    ) public onlyOwner returns (bool) {
        require(_phaseRewardTotal > 0, "Zero phase reward total");
        vestingDetail[noOfVestings] = Vesting(
            _rootHash,
            _startTime,
            _phaseRewardTotal,
            0
        );
        noOfVestings++;
        return true;
    }

    function addPhaseReward(uint256 phaseNo, uint256 amount)
        internal
        checkPhaseNo(phaseNo)
    {
        require(
            vestingDetail[phaseNo].phaseRewardBalance + amount <=
                vestingDetail[phaseNo].phaseRewardTotal,
            "Adding more than phase required tokens"
        );
        vestingDetail[phaseNo].phaseRewardBalance += amount;
        ERC20Interface.safeTransferFrom(msg.sender, address(this), amount);
    }

    function addMultiplePhaseRewards(
        uint256[] calldata phaseNo,
        uint256[] calldata amount
    ) external onlyOwner {
        require(phaseNo.length == amount.length, "Length mismatch");
        for (uint256 i; i < phaseNo.length; i++) {
            addPhaseReward(phaseNo[i], amount[i]);
        }
    }

    function changeStartTime(uint256 phaseNo, uint256 _startTime)
        external
        onlyOwner
        checkPhaseNo(phaseNo)
    {
        require(
            block.timestamp < vestingDetail[phaseNo].startTime,
            "Start time already reached"
        );
        vestingDetail[phaseNo].startTime = _startTime;
    }

    function pauseVesting(uint256 phaseNo)
        external
        onlyOwner
        checkPhaseNo(phaseNo)
    {
        require(!paused[phaseNo], "Already paused");
        paused[phaseNo] = true;
    }

    function unPauseVesting(uint256 phaseNo)
        external
        onlyOwner
        checkPhaseNo(phaseNo)
    {
        require(paused[phaseNo], "Already unpaused");
        paused[phaseNo] = false;
    }

    function claimTokens(
        uint256 amount,
        uint256 phaseNo,
        bytes32[] calldata proof
    ) public checkPhaseNo(phaseNo) returns (bool) {
        require(
            block.timestamp >= vestingDetail[phaseNo].startTime,
            "Start time not reached"
        );
        require(!paused[phaseNo], "Vesting paused");
        require(!hasClaimed[msg.sender][phaseNo], "Already claimed");
        require(
            verify(msg.sender, amount, proof, vestingDetail[phaseNo].rootHash),
            "Wrong details"
        );
        require(
            vestingDetail[phaseNo].phaseRewardBalance > amount &&
                vestingDetail[phaseNo].phaseRewardBalance - amount >= 0,
            "Not enough tokens for this phase"
        );
        hasClaimed[msg.sender][phaseNo] = true;
        vestingDetail[phaseNo].phaseRewardBalance -= amount;
        ERC20Interface.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, phaseNo, amount);
        return true;
    }

    function claimMultiple(
        uint256[] calldata amount,
        uint256[] calldata phaseNo,
        bytes32[][] calldata proof
    ) external {
        uint256 len = amount.length;
        require(
            len == phaseNo.length && len == proof.length,
            "Length mismatch"
        );
        for (uint256 i; i < len; i++) {
            require(
                claimTokens(amount[i], phaseNo[i], proof[i]),
                "Claim failed"
            );
        }
    }

    function verify(
        address user,
        uint256 amount,
        bytes32[] calldata proof,
        bytes32 rootHash
    ) public pure returns (bool) {
        return (
            MerkleProof.verify(
                proof,
                rootHash,
                keccak256(abi.encodePacked(user, amount))
            )
        );
    }

    function tokenBalance() external view returns (uint256) {
        return ERC20Interface.balanceOf(address(this));
    }

    modifier checkPhaseNo(uint256 phaseNo) {
        require(phaseNo >= 0 && phaseNo < noOfVestings, "Invalid phase number");
        _;
    }
}
