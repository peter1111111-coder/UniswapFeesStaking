// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

contract StakedFeeCollector is Ownable, ReentrancyGuard, IERC721Receiver {
    struct Stake {
        uint256 amount;
        uint256 timestamp;
        bool isActive;
    }
    
    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public constant MIN_STAKE_PERIOD = 7 * 24 * 60 * 60;

    // Staker tracking
    mapping(uint256 => address) public stakerByIndex;
    mapping(address => uint256) public stakerIndex;
    uint256 public stakerCount;

    // Fee collector related state
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    mapping(uint256 => bool) public registeredPositions;
    mapping(address => mapping(address => uint256)) public unclaimedRewards;
    
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event FeesCollected(uint256 tokenId, uint256 amount0, uint256 amount1);
    event FeesDistributed(address token, uint256 amount);
    event RewardsClaimed(address indexed user, address token, uint256 amount);
    event StakerAdded(address indexed staker, uint256 index);
    event StakerRemoved(address indexed staker, uint256 index);

    constructor(address _nonfungiblePositionManager) {
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
    }

    function stake() external payable nonReentrant {
        require(msg.value > 0, "Must stake some ETH");
        
        if (!stakes[msg.sender].isActive) {
            // New staker
            stakerByIndex[stakerCount] = msg.sender;
            stakerIndex[msg.sender] = stakerCount;
            emit StakerAdded(msg.sender, stakerCount);
            stakerCount++;
            
            stakes[msg.sender] = Stake({
                amount: msg.value,
                timestamp: block.timestamp,
                isActive: true
            });
        } else {
            // Additional stake resets timestamp
            stakes[msg.sender].amount += msg.value;
            stakes[msg.sender].timestamp = block.timestamp;
        }
        
        totalStaked += msg.value;
        emit Staked(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(stakes[msg.sender].isActive, "No active stake");
        require(
            block.timestamp >= stakes[msg.sender].timestamp + MIN_STAKE_PERIOD, 
            "Minimum stake period not met"
        );
        require(amount <= stakes[msg.sender].amount, "Insufficient stake balance");
        
        stakes[msg.sender].amount -= amount;
        totalStaked -= amount;
        
        if (stakes[msg.sender].amount == 0) {
            stakes[msg.sender].isActive = false;
            // Remove staker from tracking
            uint256 index = stakerIndex[msg.sender];
            address lastStaker = stakerByIndex[stakerCount - 1];
            
            stakerByIndex[index] = lastStaker;
            stakerIndex[lastStaker] = index;
            
            delete stakerByIndex[stakerCount - 1];
            delete stakerIndex[msg.sender];
            stakerCount--;
            
            emit StakerRemoved(msg.sender, index);
        }
        
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }

    function calculateShare(address user) public view returns (uint256) {
        if (!stakes[user].isActive || totalStaked == 0) return 0;
        return (stakes[user].amount * 1e18) / totalStaked;
    }

    function distributeFees(address[] calldata tokens) external onlyOwner {
        require(totalStaked > 0, "No stakers");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            require(balance > 0, "No fees to distribute");
            
            uint256 totalDistributed = 0;
            uint256 lastStakerIndex = stakerCount - 1;
            
            for (uint256 j = 0; j < stakerCount; j++) {
                address staker = stakerByIndex[j];
                if (!stakes[staker].isActive) continue;
                
                uint256 share;
                if (j == lastStakerIndex) {
                    // Last staker gets remaining balance to avoid dust
                    share = balance - totalDistributed;
                } else {
                    // Calculate share with higher precision
                    share = (balance * stakes[staker].amount * 1e18) / totalStaked;
                    share = share / 1e18;
                }
                
                if (share > 0) {
                    unclaimedRewards[staker][token] += share;
                    totalDistributed += share;
                }
            }
            
            emit FeesDistributed(token, balance);
        }
    }

    function getStakers() public view returns (address[] memory) {
        address[] memory _stakers = new address[](stakerCount);
        for (uint256 i = 0; i < stakerCount; i++) {
            _stakers[i] = stakerByIndex[i];
        }
        return _stakers;
    }

    function collectFees(uint256 tokenId) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        require(registeredPositions[tokenId], "Position not registered");
        
        INonfungiblePositionManager.CollectParams memory params = 
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (amount0, amount1) = nonfungiblePositionManager.collect(params);
        emit FeesCollected(tokenId, amount0, amount1);
    }

    function claimRewards(address[] calldata tokens) external nonReentrant {
        uint256 totalClaimed = 0;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 reward = unclaimedRewards[msg.sender][token];
            if (reward > 0) {
                unclaimedRewards[msg.sender][token] = 0;
                require(IERC20(token).transfer(msg.sender, reward), "Transfer failed");
                emit RewardsClaimed(msg.sender, token, reward);
                totalClaimed += reward;
            }
        }
        
        require(totalClaimed > 0, "No rewards to claim");
    }

    function registerPosition(uint256 tokenId) external onlyOwner {
        registeredPositions[tokenId] = true;
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes calldata /* data */
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}

    function isStaker(address user) public view returns (bool) {
        return stakes[user].isActive;
    }

    function getStakedAmount(address user) public view returns (uint256) {
        return stakes[user].amount;
    }

    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 timestamp,
        bool isActive
    ) {
        Stake memory stake = stakes[user];
        return (stake.amount, stake.timestamp, stake.isActive);
    }

    function getUnclaimedRewards(
        address user,
        address token
    ) external view returns (uint256) {
        return unclaimedRewards[user][token];
    }

    function isUnlocked(address user) external view returns (bool) {
        return block.timestamp >= stakes[user].timestamp + MIN_STAKE_PERIOD;
    }

    function isPositionRegistered(uint256 tokenId) external view returns (bool) {
        return registeredPositions[tokenId];
    }

    function depositPosition(uint256 tokenId) external onlyOwner {
        // Transfer the LP position NFT to this contract
        nonfungiblePositionManager.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );
        registeredPositions[tokenId] = true;
    }

    function withdrawPosition(uint256 tokenId) external onlyOwner {
        require(registeredPositions[tokenId], "Position not registered");
        
        // Remove position from tracking
        registeredPositions[tokenId] = false;
        
        // Transfer the LP position NFT back to owner
        nonfungiblePositionManager.safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );
    }
} 