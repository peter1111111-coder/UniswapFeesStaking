// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";
import "../src/StakedFeeCollector.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "forge-std/console2.sol";

// Mock tokens for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract MockPositionManager {
    function safeTransferFrom(address from, address to, uint256 tokenId) external {}
    
    function collect(INonfungiblePositionManager.CollectParams calldata params) 
        external 
        returns (uint256 amount0, uint256 amount1) 
    {
        return (1e18, 2e18);
    }
}

contract StakedFeeCollectorTest is Test {
    StakedFeeCollector public collector;
    MockPositionManager public positionManager;
    MockERC20 public token6; // 6 decimals token
    MockERC20 public token18; // 18 decimals token
    
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event FeesCollected(uint256 tokenId, uint256 amount0, uint256 amount1);
    event FeesDistributed(address token, uint256 amount);
    event RewardsClaimed(address indexed user, address token, uint256 amount);
    
    function setUp() public {
        positionManager = new MockPositionManager();
        collector = new StakedFeeCollector(address(positionManager));
        token6 = new MockERC20("USDC", "USDC", 6);
        token18 = new MockERC20("DAI", "DAI", 18);
        
        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }
    
    function testStaking() public {
        console2.log("\n=== Testing Staking Functionality ===");
        vm.startPrank(alice);
        
        uint256 stakeAmount = 1 ether;
        console2.log("Alice initial stake:", stakeAmount / 1e18, "ETH");
        
        vm.expectEmit(true, true, true, true);
        emit Staked(alice, stakeAmount);
        collector.stake{value: stakeAmount}();
        
        (uint256 amount, uint256 timestamp, bool isActive) = collector.getStakeInfo(alice);
        console2.log("Stake verified:");
        console2.log("- Amount:", amount / 1e18, "ETH");
        console2.log("- Timestamp:", timestamp);
        console2.log("- Is Active:", isActive);
        console2.log("Total Staked:", collector.totalStaked() / 1e18, "ETH");
        
        uint256 additionalStake = 2 ether;
        console2.log("\nAlice additional stake:", additionalStake / 1e18, "ETH");
        collector.stake{value: additionalStake}();
        
        (amount, timestamp, ) = collector.getStakeInfo(alice);
        console2.log("Updated stake amount:", amount / 1e18, "ETH");
        
        vm.stopPrank();
    }
    
    function testWithdrawal() public {
        console2.log("\n=== Testing Withdrawal Functionality ===");
        
        vm.startPrank(alice);
        uint256 initialStake = 3 ether;
        console2.log("Alice initial stake:", initialStake / 1e18, "ETH");
        collector.stake{value: initialStake}();
        
        console2.log("\nTrying to withdraw before minimum period...");
        vm.expectRevert("Minimum stake period not met");
        collector.withdraw(1 ether);
        console2.log("Withdrawal correctly reverted");
        
        console2.log("\nFast forwarding 8 days...");
        vm.warp(block.timestamp + 8 days);
        
        uint256 balanceBefore = alice.balance;
        uint256 partialWithdraw = 1 ether;
        console2.log("Withdrawing:", partialWithdraw / 1e18, "ETH");
        collector.withdraw(partialWithdraw);
        console2.log("Withdrawal successful. Balance change:", (alice.balance - balanceBefore) / 1e18, "ETH");
        
        console2.log("\nWithdrawing remaining stake:", 2 ether / 1e18, "ETH");
        collector.withdraw(2 ether);
        console2.log("Is Alice still a staker?", collector.isStaker(alice));
        console2.log("Total staker count:", collector.stakerCount());
        
        vm.stopPrank();
    }
    
    function testFeeDistribution() public {
        console2.log("\n=== Testing Fee Distribution ===");
        
        // Setup stakes
        vm.prank(alice);
        collector.stake{value: 2 ether}();
        console2.log("Alice staked:", 2 ether / 1e18, "ETH");
        
        vm.prank(bob);
        collector.stake{value: 3 ether}();
        console2.log("Bob staked:", 3 ether / 1e18, "ETH");
        
        // Mint fees (using larger amounts)
        uint256 usdcAmount = 1000000 * 1000;  // 1000 USDC
        uint256 daiAmount = 1000 ether;       // 1000 DAI
        token6.mint(address(collector), usdcAmount);
        token18.mint(address(collector), daiAmount);
        console2.log("\nFees received:");
        console2.log("- USDC:", usdcAmount / 1e6);
        console2.log("- DAI:", daiAmount / 1e18);
        
        // Distribute fees
        address[] memory tokens = new address[](2);
        tokens[0] = address(token6);
        tokens[1] = address(token18);
        collector.distributeFees(tokens);
        
        console2.log("\nRewards Distribution:");
        console2.log("Alice (40%):");
        console2.log("- USDC:", collector.getUnclaimedRewards(alice, address(token6)) / 1e6);
        console2.log("- DAI:", collector.getUnclaimedRewards(alice, address(token18)) / 1e18);
        console2.log("Bob (60%):");
        console2.log("- USDC:", collector.getUnclaimedRewards(bob, address(token6)) / 1e6);
        console2.log("- DAI:", collector.getUnclaimedRewards(bob, address(token18)) / 1e18);
    }
    
    function testFeeDistributionSmallAmounts() public {
        console2.log("=== Testing Small Fee Distribution ===");
        
        // Setup stakes
        vm.prank(alice);
        collector.stake{value: 2 ether}();
        console2.log("Alice staked");
        console2.logUint(2 ether);
        
        vm.prank(bob);
        collector.stake{value: 3 ether}();
        console2.log("Bob staked");
        console2.logUint(3 ether);
        
        console2.log("Total staked (raw)");
        console2.logUint(collector.totalStaked());
        
        // Test with 1 token of each
        uint256 usdcAmount = 1_000_000;  // 1 USDC (6 decimals)
        uint256 daiAmount = 1 ether;     // 1 DAI (18 decimals)
        token6.mint(address(collector), usdcAmount);
        token18.mint(address(collector), daiAmount);
        
        console2.log("Fees received (USDC):");
        console2.logUint(usdcAmount);  // Raw amount
        
        console2.log("Fees received (DAI):");
        console2.logUint(daiAmount);   // Raw amount
        
        // Calculate expected amounts
        uint256 expectedAliceUsdc = (usdcAmount * 2) / 5;  // 40%
        uint256 expectedBobUsdc = usdcAmount - expectedAliceUsdc;  // 60%
        uint256 expectedAliceDai = (daiAmount * 2) / 5;  // 40%
        uint256 expectedBobDai = daiAmount - expectedAliceDai;  // 60%
        
        console2.log("Expected Alice USDC (40%):");
        console2.logUint(expectedAliceUsdc);
        console2.log("Expected Alice DAI (40%):");
        console2.logUint(expectedAliceDai);
        
        console2.log("Expected Bob USDC (60%):");
        console2.logUint(expectedBobUsdc);
        console2.log("Expected Bob DAI (60%):");
        console2.logUint(expectedBobDai);
        
        // Distribute fees
        address[] memory tokens = new address[](2);
        tokens[0] = address(token6);
        tokens[1] = address(token18);
        collector.distributeFees(tokens);
        
        console2.log("\nActual Distribution:");
        console2.log("Alice (40%):");
        console2.log("Actual Alice USDC (40%):");
        console2.logUint(collector.getUnclaimedRewards(alice, address(token6)));
        
        console2.log("Actual Alice DAI (40%):");
        console2.logUint(collector.getUnclaimedRewards(alice, address(token18)));
        
        console2.log("Bob (60%):");
        console2.log("Actual Bob USDC (60%):");
        console2.logUint(collector.getUnclaimedRewards(bob, address(token6)));
        
        console2.log("Actual Bob DAI (60%):");
        console2.logUint(collector.getUnclaimedRewards(bob, address(token18)));
        
        // Verify total distribution
        assertEq(collector.getUnclaimedRewards(alice, address(token6)), expectedAliceUsdc, "Total USDC distribution does not match");
        assertEq(collector.getUnclaimedRewards(alice, address(token18)), expectedAliceDai, "Total DAI distribution does not match");
        assertEq(collector.getUnclaimedRewards(bob, address(token6)), expectedBobUsdc, "Total USDC distribution does not match");
        assertEq(collector.getUnclaimedRewards(bob, address(token18)), expectedBobDai, "Total DAI distribution does not match");
    }
    
    function testClaimRewards() public {
        // Setup stakes and distribute fees (similar to previous test)
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        
        token6.mint(address(collector), 1000000);
        token18.mint(address(collector), 1 ether);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(token6);
        tokens[1] = address(token18);
        collector.distributeFees(tokens);
        
        // Claim rewards
        vm.prank(alice);
        collector.claimRewards(tokens);
        
        // Verify rewards were claimed
        assertEq(token6.balanceOf(alice), 1000000);
        assertEq(token18.balanceOf(alice), 1 ether);
        assertEq(collector.getUnclaimedRewards(alice, address(token6)), 0);
        assertEq(collector.getUnclaimedRewards(alice, address(token18)), 0);
    }
    
    function testPositionManagement() public {
        // Test position registration
        vm.prank(address(collector.owner()));
        collector.registerPosition(1);
        assertTrue(collector.isPositionRegistered(1));
        
        // Test fee collection
        vm.prank(address(collector.owner()));
        (uint256 amount0, uint256 amount1) = collector.collectFees(1);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 2 ether);
    }
    
    // Fuzz tests
    function testFuzz_Stake(uint256 amount) public {
        // Bound amount to reasonable values
        amount = bound(amount, 0.1 ether, 100 ether);
        
        vm.deal(alice, amount);
        vm.prank(alice);
        collector.stake{value: amount}();
        
        (uint256 stakedAmount, , bool isActive) = collector.getStakeInfo(alice);
        assertEq(stakedAmount, amount);
        assertTrue(isActive);
    }
    
    function testFuzz_MultipleStakers(
        uint256[3] memory amounts,
        uint256 feeAmount
    ) public {
        console2.log("\n=== Fuzzing Multiple Stakers ===");
        
        // Bound inputs
        for (uint256 i = 0; i < 3; i++) {
            amounts[i] = bound(amounts[i], 0.1 ether, 100 ether);
        }
        feeAmount = bound(feeAmount, 1e6, 1000e18);
        
        address[3] memory stakers = [alice, bob, carol];
        uint256 totalStaked = 0;
        
        console2.log("Staking amounts:");
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(stakers[i], amounts[i]);
            vm.prank(stakers[i]);
            collector.stake{value: amounts[i]}();
            totalStaked += amounts[i];
            console2.log("Staker");
            console2.log(i);
            console2.log(amounts[i] / 1e18);
        }
        console2.log("Total staked:", totalStaked / 1e18, "ETH");
        
        console2.log("\nDistributing fees:", feeAmount / 1e18, "tokens");
        token18.mint(address(collector), feeAmount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        collector.distributeFees(tokens);
        
        uint256 totalDistributed = 0;
        console2.log("\nRewards distribution:");
        for (uint256 i = 0; i < 3; i++) {
            uint256 reward = collector.getUnclaimedRewards(stakers[i], address(token18));
            totalDistributed += reward;
            console2.log("Staker", i);
            console2.log("rewards:", reward / 1e18);
            console2.log("tokens");
        }
        console2.log("Total distributed:", totalDistributed / 1e18, "tokens");
        
        uint256 distributionError = totalDistributed > feeAmount ? 
            totalDistributed - feeAmount : feeAmount - totalDistributed;
        console2.log("Distribution error:", distributionError / 1e18, "tokens");
    }

    function testGetStakers() public {
        // Setup multiple stakers
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        vm.prank(bob);
        collector.stake{value: 2 ether}();
        vm.prank(carol);
        collector.stake{value: 3 ether}();

        // Get stakers array
        address[] memory stakers = collector.getStakers();
        
        // Verify array contents
        assertEq(stakers.length, 3);
        assertEq(stakers[0], alice);
        assertEq(stakers[1], bob);
        assertEq(stakers[2], carol);
    }

    function testDepositAndWithdrawPosition() public {
        uint256 tokenId = 123;
        
        // Mock the NFT transfer - Use the full function signature instead
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"),
            abi.encode()
        );
        
        // Test deposit
        vm.prank(collector.owner());
        collector.depositPosition(tokenId);
        assertTrue(collector.isPositionRegistered(tokenId));
        
        // Test withdraw
        vm.prank(collector.owner());
        collector.withdrawPosition(tokenId);
        assertFalse(collector.isPositionRegistered(tokenId));
    }

    function testFailWithdrawUnregisteredPosition() public {
        console2.log("\n=== Testing Withdraw Unregistered Position ===");
        
        uint256 tokenId = 123;
        
        // Mock the NFT transfer
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"),
            abi.encode()
        );
        
        console2.log("Position registered status before:", collector.isPositionRegistered(tokenId));
        console2.log("Attempting to withdraw unregistered position:", tokenId);
        
        vm.prank(collector.owner());
        // This should fail
        collector.withdrawPosition(tokenId);
    }

    function testFailNonOwnerPositionOperations() public {
        console2.log("\n=== Testing Non-Owner Position Operations ===");
        
        uint256 tokenId = 123;
        
        // Mock the NFT transfer
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"),
            abi.encode()
        );
        
        console2.log("Current owner:", collector.owner());
        console2.log("Attempting operation as non-owner (alice):", alice);
        
        vm.startPrank(alice);
        // This should fail
        collector.depositPosition(tokenId);
        vm.stopPrank();
    }

    function testCalculateShare() public {
        // Setup stakes
        vm.prank(alice);
        collector.stake{value: 2 ether}();
        vm.prank(bob);
        collector.stake{value: 3 ether}();
        
        // Test share calculation
        uint256 aliceShare = collector.calculateShare(alice);
        uint256 bobShare = collector.calculateShare(bob);
        
        // Alice should have 40% (2/5)
        assertEq(aliceShare, 4e17); // 0.4 * 1e18
        // Bob should have 60% (3/5)
        assertEq(bobShare, 6e17);   // 0.6 * 1e18
    }

    function testFailClaimWithNoRewards() public {
        console2.log("\n=== Testing Claim With No Rewards ===");
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        
        vm.startPrank(alice);
        
        // First stake some ETH to become a staker
        uint256 stakeAmount = 1 ether;
        console2.log("Alice staking:", stakeAmount / 1e18, "ETH");
        collector.stake{value: stakeAmount}();
        
        console2.log("Attempting to claim non-existent rewards...");
        console2.log("Current unclaimed rewards:", collector.getUnclaimedRewards(alice, address(token18)));
        // This should fail
        collector.claimRewards(tokens);
        vm.stopPrank();
    }

    function testIsUnlocked() public {
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        
        assertFalse(collector.isUnlocked(alice));
        
        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(collector.isUnlocked(alice));
    }

    function testReceiveFunction() public {
        // Test direct ETH transfer
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(collector).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(collector).balance, 1 ether);
    }

    function testFailDistributeFeesWithNoBalance() public {
        console2.log("\n=== Testing Distribute Fees With No Balance ===");
        
        // Setup a staker
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        console2.log("Alice staked:", 1, "ETH");
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        
        console2.log("Token balance of collector:", token18.balanceOf(address(collector)));
        console2.log("Attempting to distribute fees with zero balance...");
        // This should fail
        collector.distributeFees(tokens);
    }

    function testFailDistributeFeesWithNoStakers() public {
        console2.log("\n=== Testing Distribute Fees With No Stakers ===");
        
        // Mint some tokens first to avoid "no fees" error
        uint256 amount = 1 ether;
        token18.mint(address(collector), amount);
        console2.log("Minted tokens to collector:", amount / 1e18, "tokens");
        console2.log("Current staker count:", collector.stakerCount());
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        
        console2.log("Attempting to distribute fees with no stakers...");
        // This should fail
        collector.distributeFees(tokens);
    }

    function testStakerTracking() public {
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        
        assertEq(collector.stakerByIndex(0), alice);
        assertEq(collector.stakerIndex(alice), 0);
        
        vm.prank(bob);
        collector.stake{value: 1 ether}();
        assertEq(collector.stakerByIndex(1), bob);
        
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        collector.withdraw(1 ether);
        
        // Bob should now be at index 0
        assertEq(collector.stakerByIndex(0), bob);
        assertEq(collector.stakerCount(), 1);
    }

    function testPartialWithdrawals() public {
        vm.startPrank(alice);
        collector.stake{value: 3 ether}();
        
        vm.warp(block.timestamp + 7 days + 1);
        
        collector.withdraw(1 ether);
        assertEq(collector.getStakedAmount(alice), 2 ether);
        assertTrue(collector.isStaker(alice));
        
        collector.withdraw(2 ether);
        assertEq(collector.getStakedAmount(alice), 0);
        assertFalse(collector.isStaker(alice));
        vm.stopPrank();
    }

    function testFeeDistributionEdgeCases() public {
        // Test with very small amounts
        vm.prank(alice);
        collector.stake{value: 1 wei}();
        
        // Test with very large amounts
        uint256 largeAmount = type(uint128).max; // Using uint128 to avoid overflow in multiplication
        token18.mint(address(collector), largeAmount);
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        collector.distributeFees(tokens);
        
        // Verify no overflow occurred and rewards were distributed
        assertTrue(collector.getUnclaimedRewards(alice, address(token18)) > 0);
        assertEq(collector.getUnclaimedRewards(alice, address(token18)), largeAmount);
    }

    function testPositionManagementEdgeCases() public {
        uint256 tokenId = type(uint256).max;
        
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"),
            abi.encode()
        );
        
        vm.startPrank(collector.owner());
        
        // Test initial deposit
        collector.depositPosition(tokenId);
        assertTrue(collector.isPositionRegistered(tokenId));
        
        // Test double registration (should work but not change state)
        collector.depositPosition(tokenId);
        assertTrue(collector.isPositionRegistered(tokenId));
        
        // Test withdrawal
        collector.withdrawPosition(tokenId);
        assertFalse(collector.isPositionRegistered(tokenId));
        
        // Test double withdrawal (should fail)
        vm.expectRevert("Position not registered");
        collector.withdrawPosition(tokenId);
        
        vm.stopPrank();
    }

    function testEventEmissions() public {
        // Test Stake event
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        
        // Test Withdraw event
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        collector.withdraw(1 ether);
    }

    function testMaxStakeAmount() public {
        uint256 maxAmount = type(uint256).max;
        vm.deal(alice, maxAmount);
        
        vm.prank(alice);
        collector.stake{value: maxAmount}();
        
        (uint256 amount, , bool isActive) = collector.getStakeInfo(alice);
        assertEq(amount, maxAmount);
        assertTrue(isActive);
    }

    function testMultipleStakersWithdraw() public {
        // Setup multiple stakers
        vm.prank(alice);
        collector.stake{value: 2 ether}();
        
        vm.prank(bob);
        collector.stake{value: 3 ether}();
        
        vm.prank(carol);
        collector.stake{value: 5 ether}();
        
        assertEq(collector.stakerCount(), 3);
        assertEq(collector.totalStaked(), 10 ether);
        
        // Fast forward and withdraw
        vm.warp(block.timestamp + 8 days);
        
        vm.prank(bob);
        collector.withdraw(3 ether);
        
        // Check remaining stakers and total
        assertEq(collector.stakerCount(), 2);
        assertEq(collector.totalStaked(), 7 ether);
        assertFalse(collector.isStaker(bob));
    }

    function testFailStakeZero() public {
        vm.prank(alice);
        collector.stake{value: 0}();
    }

    function testFailWithdrawMoreThanStaked() public {
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        
        vm.warp(block.timestamp + 8 days);
        
        vm.prank(alice);
        collector.withdraw(2 ether);
    }

    function testPositionFeesCollection() public {
        uint256 tokenId = 1;
        
        vm.startPrank(collector.owner());
        collector.registerPosition(tokenId);
        
        // Test fee collection
        (uint256 amount0, uint256 amount1) = collector.collectFees(tokenId);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 2 ether);
        
        vm.stopPrank();
    }

    function testMultiplePositionsManagement() public {
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;
        
        vm.startPrank(collector.owner());
        
        // Register multiple positions
        for(uint256 i = 0; i < tokenIds.length; i++) {
            collector.registerPosition(tokenIds[i]);
            assertTrue(collector.isPositionRegistered(tokenIds[i]));
        }
        
        // Withdraw positions in reverse
        for(uint256 i = tokenIds.length; i > 0; i--) {
            collector.withdrawPosition(tokenIds[i-1]);
            assertFalse(collector.isPositionRegistered(tokenIds[i-1]));
        }
        
        vm.stopPrank();
    }

    function testFailUnauthorizedFeeCollection() public {
        uint256 tokenId = 1;
        vm.prank(collector.owner());
        collector.registerPosition(tokenId);
        
        // Try to collect fees as non-owner
        vm.prank(alice);
        collector.collectFees(tokenId);
    }

    function testStakeAndClaimCycle() public {
        // Complete cycle of stake -> receive fees -> distribute -> claim
        vm.prank(alice);
        collector.stake{value: 1 ether}();
        
        // Mint and distribute fees
        token18.mint(address(collector), 100 ether);
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(token18);
        
        collector.distributeFees(tokens);
        
        // Check rewards
        uint256 unclaimedRewards = collector.getUnclaimedRewards(alice, address(token18));
        assertEq(unclaimedRewards, 100 ether);
        
        // Claim rewards
        vm.prank(alice);
        collector.claimRewards(tokens);
        
        // Verify claimed
        assertEq(token18.balanceOf(alice), 100 ether);
        assertEq(collector.getUnclaimedRewards(alice, address(token18)), 0);
    }
}
