// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CPAMM} from "../../src/core/CPAMM.sol";
import {CPAMMFactory} from "../../src/core/CPAMMFactory.sol";
import {CPAMMRouter} from "../../src/periphery/CPAMMRouter.sol";
import {CPAMMOracle} from "../../src/periphery/CPAMMOracle.sol";
import {CPAMMGovernance} from "../../src/periphery/CPAMMGovernance.sol";
import {CPAMMLiquidityProvider} from "../../src/periphery/CPAMMLiquidityProvider.sol";
import {UniswapV4Pair} from "../../src/core/UniswapV4Pair.sol";
import {UniswapV4Utils} from "../../src/lib/UniswapV4Utils.sol";
import {CPAMMUtils} from "../../src/lib/CPAMMUtils.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CPAMMHelpers} from "../helpers/CPAMMHelpers.t.sol";
import {ICPAMMFactory} from "../../src/Interfaces/ICPAMMFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // Import IERC20
import {HookMiner} from "../../test/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ICPAMMHook} from "../../src/Interfaces/ICPAMMHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {ReserveTrackingHook} from "../../src/core/ReserveTrackingHook.sol";

contract CPAMMTest is Test, CPAMMHelpers {
    using UniswapV4Utils for uint160;
    using UniswapV4Utils for uint256;
    using CPAMMUtils for uint256;

    MockPoolManager public mockPoolManager;

    // Test contracts
    CPAMMFactory factory;
    CPAMM hook;
    CPAMMRouter router;
    CPAMMOracle oracle;
    CPAMMGovernance governance;
    CPAMMLiquidityProvider liquidityProvider;
    UniswapV4Pair pair;
    IPoolManager poolManager;

    // Test tokens
    MockERC20 token0;
    MockERC20 token1;

    // Test accounts
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address authorizedUser = makeAddr("authorizedUser");
    address unauthorizedUser = makeAddr("unauthorizedUser");

    // Test constants
    uint24 constant FEE = 3000; // 0.3%
    uint160 constant INITIAL_SQRT_PRICE = UniswapV4Utils.MIN_SQRT_RATIO + 1;
    uint256 constant INITIAL_LIQUIDITY = 1000000 * 1e18;
    uint256 constant SWAP_AMOUNT = 1000 * 1e18;
    uint256 constant MIN_LIQUIDITY = 1000;

    uint24 constant DEFAULT_FEE = CPAMMUtils.DEFAULT_FEE;
    uint256 constant DEFAULT_SLIPPAGE = CPAMMUtils.DEFAULT_SLIPPAGE;
    uint24 constant DEFAULT_PROTOCOL_FEE = CPAMMUtils.DEFAULT_PROTOCOL_FEE;

    address constant TOKEN_A = address(0x1);
    address constant TOKEN_B = address(0x2);
    address constant HOOK_ADDRESS = address(0x3);

    // Events to test
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 fee,
        address hook
    );

    event LiquidityAdded(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address to
    );

    event LiquidityRemoved(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    function setUp() public {
        // Deploy PoolManager
        if (address(poolManager) == address(0)) {
            // deploy and wire both references
            mockPoolManager = new MockPoolManager();
            poolManager = IPoolManager(address(mockPoolManager));
        }

        // Define required hook permissions flags
        uint160 hookBits = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.AFTER_DONATE_FLAG
        );

        // Get creation code and constructor arguments
        bytes memory creationCode = type(ReserveTrackingHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager);
        bytes memory deploymentData = abi.encodePacked(
            creationCode,
            constructorArgs
        );

        // Find salt and address using HookMiner
        (bytes32 salt, address hookAddress) = HookMiner.find(
            address(this), // deployer
            hookBits, // flags
            creationCode, // creationCode
            constructorArgs // constructorArgs
        );

        // Deploy hook with CREATE2
        address deployedHook;
        assembly {
            deployedHook := create2(
                0, // value (0 ETH)
                add(deploymentData, 0x20), // offset
                mload(deploymentData), // length
                salt // salt
            )
            if iszero(deployedHook) {
                revert(0, 0) // Revert if deployment fails
            }
        }

        // Assign deployed hook
        ReserveTrackingHook reserveHook = ReserveTrackingHook(deployedHook);

        // Deploy router before factory
        router = new CPAMMRouter(poolManager);

        // Deploy factory with the correctly deployed hook
        factory = new CPAMMFactory(
            poolManager,
            owner,
            address(reserveHook),
            owner,
            address(router) // Pass router address
        );

        governance = new CPAMMGovernance(poolManager, address(factory));

        // point the hook at its governance
        reserveHook.setGovernance(address(governance));

        // Now patch the router so its `factory` pointer is correct
        router.setFactory(address(factory));
      
        // Deploy tokens
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Create pool
        (PoolId pid, address hookAddr) = factory.createPool(
            address(token0),
            address(token1),
            FEE,
            INITIAL_SQRT_PRICE
        );

        /*/ Remaining setup code
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: UniswapV4Utils.DEFAULT_TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        address poolAddress = MockPoolManager(address(poolManager)).pools(key);
        pair = UniswapV4Pair(poolAddress);*/

        // Grab the real pair from the factory
        address pairAddress = factory.getPair(pid);
        pair = UniswapV4Pair(pairAddress);

       // router = new CPAMMRouter(ICPAMMFactory(address(factory)), poolManager);
        oracle = new CPAMMOracle(ICPAMMFactory(address(factory)));
        
        // Allow our test’s `authorizedUser` to create proposals
        governance.setAuthorization(authorizedUser, true);

        liquidityProvider = new CPAMMLiquidityProvider(
            ICPAMMFactory(address(factory)),
            poolManager
        );
    }

    function computeCreate2Address(
        uint256 salt,
        bytes32 bytecodeHash
    ) internal view returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xFF),
                                address(this),
                                salt,
                                bytecodeHash
                            )
                        )
                    )
                )
            );
    }

    // Test core pool operations
    function testCreatePool() public {
        vm.startPrank(user1);

        address token2 = address(new MockERC20("Token2", "TK2", 18));
        address token3 = address(new MockERC20("Token3", "TK3", 18));

        (PoolId poolId, address hookAddr) = _createTestPool(
            factory,
            token2,
            token3,
            FEE,
            INITIAL_SQRT_PRICE
        );

        // Validate pool creation results
        assertTrue(hookAddr != address(0), "Hook address should not be zero");
        assertTrue(
            factory.getHook(poolId) == hookAddr,
            "Hook not registered in factory"
        );
        assertTrue(
            factory.poolExists(poolId),
            "Pool not registered in factory"
        );

        vm.stopPrank();
    }

    function testPairMint() public {
        vm.startPrank(user1);

        // Mint tokens to user1
        MockERC20(token0).mint(user1, INITIAL_LIQUIDITY);
        MockERC20(token1).mint(user1, INITIAL_LIQUIDITY);

        // Approve the router to spend tokens
        token0.approve(address(router), INITIAL_LIQUIDITY);
        token1.approve(address(router), INITIAL_LIQUIDITY);

        // Set expected deltas for the mock pool manager
        PoolId pid = factory.getPoolId(address(token0), address(token1));
        int128 delta0 = -int128(int256(INITIAL_LIQUIDITY));
        int128 delta1 = -int128(int256(INITIAL_LIQUIDITY));
        mockPoolManager.setNextModifyLiquidityCallerDelta(pid, delta0, delta1);

        // Expect the LiquidityAdded event to be emitted
        vm.expectEmit(true, true, true, true, address(router));
        emit LiquidityAdded(
            user1,
            address(token0),
            address(token1),
            INITIAL_LIQUIDITY,
            INITIAL_LIQUIDITY,
            INITIAL_LIQUIDITY - MIN_LIQUIDITY,
            user1
        );

        // Add liquidity through the router
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            address(token0),
            address(token1),
            INITIAL_LIQUIDITY,
            INITIAL_LIQUIDITY,
            0,
            0,
            user1,
            block.timestamp + 1
        );

        // Retrieve the correct pair address from the factory
        address pairAddress = factory.getPair(pid);
        UniswapV4Pair pair = UniswapV4Pair(pairAddress);

        // Verify the results
        assertTrue(liquidity > 0, "Should mint non-zero liquidity");
        assertEq(pair.balanceOf(user1), liquidity, "LP balance mismatch");

        vm.stopPrank();
    }

    function testPairBurn_viaPeriphery() public {
        vm.startPrank(user1);

        // 1) Seed the mock so Router.addLiquidity will record the incoming liquidity delta
        PoolId pid = factory.getPoolId(address(token0), address(token1));
        int128 addD0 = -int128(int256(INITIAL_LIQUIDITY));
        int128 addD1 = -int128(int256(INITIAL_LIQUIDITY));
        mockPoolManager.setNextModifyLiquidityCallerDelta(pid, addD0, addD1);

        // 2) Mint & approve tokens for the router
        MockERC20(token0).mint(user1, INITIAL_LIQUIDITY);
        MockERC20(token1).mint(user1, INITIAL_LIQUIDITY);
        MockERC20(token0).approve(address(router), INITIAL_LIQUIDITY);
        MockERC20(token1).approve(address(router), INITIAL_LIQUIDITY);

        // 3) Add liquidity via the Router, capturing the LP‑amount
        (, , uint256 liquidity) = router.addLiquidity(
            address(token0),
            address(token1),
            INITIAL_LIQUIDITY,
            INITIAL_LIQUIDITY,
            0,
            0,
            user1,
            block.timestamp
        );

        // 4) Seed the mock so removeLiquidity will return those tokens
        int128 remD0 = int128(int256(INITIAL_LIQUIDITY));
        int128 remD1 = int128(int256(INITIAL_LIQUIDITY));
        mockPoolManager.setNextModifyLiquidityCallerDelta(pid, remD0, remD1);

        // 5) Approve router to pull LP tokens
        pair.approve(address(router), liquidity);
     
        // Expect the full 7‑arg periphery event (3 indexed: provider, tokenA, tokenB)
        // so we pass true for the first three, then false for the non‑indexed.
        vm.expectEmit(
            /* check provider */ true,
            /* check tokenA   */ true,
            /* check tokenB   */ true,
            /* rest topics    */ false
        );

        emit LiquidityRemoved(
            /* provider */ user1,
            /* tokenA   */ address(token0),
            /* tokenB   */ address(token1),
            /* amountA  */ INITIAL_LIQUIDITY,
            /* amountB  */ INITIAL_LIQUIDITY,
            /* liquidity*/ liquidity,
            /* to       */ user1
        );

        // 6) Call periphery removeLiquidity
        (uint256 out0, uint256 out1) = router.removeLiquidity(
            address(token0),
            address(token1),
            liquidity,
            /* amountAMin */ 0,
            /* amountBMin */ 0,
            user1,
            block.timestamp + 1
        );

        // 7) Verify we got back non‑zero amounts
        assertGt(out0, 0, "Should return non-zero amount0");
        assertGt(out1, 0, "Should return non-zero amount1");

        vm.stopPrank();
    }

    function testPairSwap() public {
        // Declare liquidity amounts
        uint256 amount0 = INITIAL_LIQUIDITY;
        uint256 amount1 = INITIAL_LIQUIDITY;

        // Setup liquidity first through router
        vm.startPrank(user1);
        
        // Mint tokens to user1
        token0.mint(user1, amount0);
        token1.mint(user1, amount1);

        // Approve router to spend tokens
        token0.approve(address(router), amount0);
        token1.approve(address(router), amount1);

        // Get pool ID
        PoolId poolId = factory.getPoolId(address(token0), address(token1));

        // Set expected deltas in mock PoolManager
        mockPoolManager.setNextModifyLiquidityCallerDelta(
            poolId,
            -int128(int256(amount0)),
            -int128(int256(amount1))
        );

        // Add liquidity through router
        router.addLiquidity(
            address(token0),
            address(token1),
            amount0,
            amount1,
            0, // amountAMin
            0, // amountBMin
            user1,
            block.timestamp + 1
        );

        // Set reserves in mock pool manager
        mockPoolManager.setReserves(poolId, amount0, amount1);

        // Switch to user2 for swap
        vm.stopPrank();
        vm.startPrank(user2);

        // Test swap
        uint256 swapAmount = SWAP_AMOUNT;
        token0.mint(user2, swapAmount);
        token0.approve(address(router), swapAmount);

        uint256 balanceBefore = token1.balanceOf(user2);

        // Set expected swap delta in mock PoolManager
        uint256 expectedOut = swapAmount / 2;
        mockPoolManager.setNextSwapDelta(
            poolId,
            int128(int256(expectedOut)), // token1 out (positive)
            -int128(int256(swapAmount))  // token0 in (negative)
        );

        // Build path
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        
        // Perform swap via router
        uint256[] memory amounts = router.swapExactTokensForTokens(
            swapAmount,
            0,
            path,
            user2,
            block.timestamp + 1
        );

        // Verify results
        assertTrue(amounts[1] > 0, "Should get non-zero amount out");
        assertEq(
            token1.balanceOf(user2),
            balanceBefore + amounts[1],
            "Balance mismatch after swap"
        );
        assertEq(amounts[1], expectedOut, "Output amount mismatch");

        vm.stopPrank();
    }

     // Helper function for swap
    function _swap(
        address tokenIn,
        address tokenOut,
        address pair,
        bool zeroForOne,
        uint256 amountIn,
        address recipient,
        uint256 expectedMinOut
    ) internal returns (uint256 amountOut) {
        // Get reserves
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne
            ? (token0.balanceOf(pair), token1.balanceOf(pair))
            : (token1.balanceOf(pair), token0.balanceOf(pair));

        // Calculate expected output
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;

        require(amountOut >= expectedMinOut, "Insufficient output amount");

        // Perform swap
        if (zeroForOne) {
            UniswapV4Pair(pair).swap(0, amountOut, recipient);
        } else {
            UniswapV4Pair(pair).swap(amountOut, 0, recipient);
        }

        return amountOut;
    }

    function testSwapViaRouter() public {
        uint256 L = INITIAL_LIQUIDITY;
        uint256 M = SWAP_AMOUNT; // e.g. 1e18

        // 1) --- seed & call addLiquidity via router as user1 ---
        vm.startPrank(user1);

        // tell the mock PoolManager to expect -L on both sides
        PoolId pid = factory.getPoolId(address(token0), address(token1));
        mockPoolManager.setNextModifyLiquidityCallerDelta(
            pid,
            -int128(int256(L)),
            -int128(int256(L))
        );

        // give user1 some tokens & approve router
        token0.mint(user1, L);
        token1.mint(user1, L);
        token0.approve(address(router), L);
        token1.approve(address(router), L);

        // actually add the liquidity
        (, , uint256 mintedLiquidity) = router.addLiquidity(
            address(token0),
            address(token1),
            L,    // amountADesired
            L,    // amountBDesired
            0,    // amountAMin
            0,    // amountBMin
            user1,
            block.timestamp + 1
        );
        assertGt(mintedLiquidity, 0, "liquidity minted");

        vm.stopPrank();


        // 2) --- now seed & call a swap via router as user2 ---
        vm.startPrank(user2);

        // tell the mock PoolManager how the balances move:
        //   +M token0 into pool,  −X token1 out of pool
        // pick some X that your mock will return
        uint256 expectedOut = M / 2;
        mockPoolManager.setNextSwapDelta(
            pid,
            int128(int256(expectedOut)), // amount0 delta (currency0 = token1, output)
            -int128(int256(M))             // amount1 delta (currency1 = token0, input)
        );
     
        // give user2 some token0 & approve router
        token0.mint(user2, M);
        token0.approve(address(router), M);

        // build a 2‑token path
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);

        // capture pre‑balance
        uint256 before = token1.balanceOf(user2);

        // watch for the Swap event
        vm.expectEmit(true, true, true, true);
        emit Swap(
            user2,
            0,          // amount0In (currency0 = token1)
            M,          // amount1In (currency1 = token0)
            expectedOut, // amount0Out (currency0 = token1)
            0,          // amount1Out (currency1 = token0)
            user2
        );

        // do the swap
        uint256[] memory amounts = router.swapExactTokensForTokens(
            M,           // amountIn
            0,           // amountOutMin
            path,
            user2,
            block.timestamp + 1
        );

        // router should return [M, expectedOut]
        assertEq(amounts.length, 2);
        assertEq(amounts[0], M);
        assertEq(amounts[1], expectedOut);

        // user2's token1 balance should have grown
        assertEq(
            token1.balanceOf(user2),
            before + expectedOut,
            "user2 got token1"
        );

        vm.stopPrank();
    }

    // Test utility functions
    function testUtilsValidation() public {
        // Test fee validation
        uint24 validFee = 3000; // 0.3%
        uint24 invalidFee = 150000; // 15%

        // Valid fee should pass
        assertEq(UniswapV4Utils.validateFee(validFee), validFee);

        // Invalid fee should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4Utils.InvalidFee.selector,
                invalidFee,
                UniswapV4Utils.MAX_FEE
            )
        );
        UniswapV4Utils.validateFee(invalidFee);

        // Test token validation
        address TOKEN_A = address(0x1);
        address TOKEN_B = address(0x2);
        address HOOK_ADDRESS = address(0x3);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4Utils.InvalidTokens.selector,
                TOKEN_A,
                TOKEN_A
            )
        );
        UniswapV4Utils.createPoolKey(TOKEN_A, TOKEN_A, validFee, HOOK_ADDRESS);

        // Test sqrt price validation
        uint160 validPrice = (UniswapV4Utils.MIN_SQRT_RATIO +
            UniswapV4Utils.MAX_SQRT_RATIO) / 2;
        uint160 invalidPriceLow = UniswapV4Utils.MIN_SQRT_RATIO - 1;
        uint160 invalidPriceHigh = UniswapV4Utils.MAX_SQRT_RATIO + 1;

        // Valid price should pass validation
        assertTrue(validPrice.validateSqrtPrice() == validPrice);

        // Invalid prices should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4Utils.InvalidSqrtPrice.selector,
                invalidPriceLow,
                UniswapV4Utils.MIN_SQRT_RATIO,
                UniswapV4Utils.MAX_SQRT_RATIO
            )
        );
        invalidPriceLow.validateSqrtPrice();

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4Utils.InvalidSqrtPrice.selector,
                invalidPriceHigh,
                UniswapV4Utils.MIN_SQRT_RATIO,
                UniswapV4Utils.MAX_SQRT_RATIO
            )
        );
        invalidPriceHigh.validateSqrtPrice();

        // Test pool key validation
        PoolKey memory validKey = PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            fee: validFee,
            tickSpacing: UniswapV4Utils.DEFAULT_TICK_SPACING,
            hooks: IHooks(HOOK_ADDRESS)
        });

        // Valid pool key should pass validation
        assertTrue(UniswapV4Utils.validatePool(validKey));

        // Test invalid pool keys
        PoolKey memory invalidKey1 = validKey;
        invalidKey1.currency0 = invalidKey1.currency1; // Same currencies
        assertFalse(UniswapV4Utils.validatePool(invalidKey1));

        PoolKey memory invalidKey2 = validKey;
        invalidKey2.hooks = IHooks(address(0)); // Zero hook address
        assertFalse(UniswapV4Utils.validatePool(invalidKey2));

        PoolKey memory invalidKey3 = validKey;
        invalidKey3.fee = invalidFee; // Invalid fee
        assertFalse(UniswapV4Utils.validatePool(invalidKey3));

        PoolKey memory invalidKey4 = validKey;
        invalidKey4.tickSpacing = 0; // Invalid tick spacing
        assertFalse(UniswapV4Utils.validatePool(invalidKey4));
    }

    function testProposalCreation() public {
        // Setup
        PoolId poolId = createMockPool(
            factory, // CPAMMFactory instance
            3000, // fee (0.3%)
            UniswapV4Utils.MIN_SQRT_RATIO // initial sqrt price
        );
        uint24 newFee = 5000; // 0.5%
        uint256 delay = 2 days;

        // Create proposal
        vm.prank(authorizedUser);
        uint256 proposalId = governance.createProposal(poolId, newFee, delay);

        // Verify proposal details
        CPAMMGovernance.Proposal memory proposal = governance.getProposal(
            proposalId
        );
        uint256 id = proposal.id;
        address proposer = proposal.proposer;
        PoolId pId = proposal.poolId;
        uint24 fee = proposal.newFee;
        uint256 pDelay = proposal.delay;
        uint256 createdAt = proposal.createdAt;
        CPAMMGovernance.ProposalState state = proposal.state;

        assertEq(id, proposalId);
        assertEq(proposer, authorizedUser);
        // Since PoolId is a user-defined value type, we can compare them directly
        assertTrue(
            PoolId.unwrap(pId) == PoolId.unwrap(poolId),
            "Pool IDs do not match"
        );
        assertEq(fee, newFee);
        assertEq(pDelay, delay);
        assertEq(uint8(state), uint8(CPAMMGovernance.ProposalState.Active));
    }

    function testProposalExecution() public {
        // Setup
        PoolId poolId = createMockPool(
            factory,
            3000,
            UniswapV4Utils.MIN_SQRT_RATIO
        );
        uint24 newFee = 5000;
        uint256 delay = 1 days;

        // Create and execute proposal
        vm.startPrank(authorizedUser);
        uint256 proposalId = governance.createProposal(poolId, newFee, delay);

        CPAMMGovernance.Proposal memory proposal = governance.getProposal(
            proposalId
        );

        // Advance time past delay
        vm.warp(block.timestamp + proposal.delay + 1);

        governance.executeProposal(proposalId);
        vm.stopPrank();

        // Verify proposal state
        proposal = governance.getProposal(proposalId);
        CPAMMGovernance.ProposalState state = proposal.state;
        assertEq(uint8(state), uint8(CPAMMGovernance.ProposalState.Executed));
    }

    function testProposalCancellation() public {
        // Setup
        PoolId poolId = createMockPool(
            factory,
            3000,
            UniswapV4Utils.MIN_SQRT_RATIO
        );
        uint24 newFee = 5000;
        uint256 delay = 1 days;

        // Create proposal
        vm.prank(authorizedUser);
        uint256 proposalId = governance.createProposal(poolId, newFee, delay);

        // Cancel proposal
        vm.prank(authorizedUser);
        governance.cancelProposal(proposalId);

        // Verify cancelled state
        CPAMMGovernance.Proposal memory proposal = governance.getProposal(
            proposalId
        );
        CPAMMGovernance.ProposalState state = proposal.state;
        assertEq(uint8(state), uint8(CPAMMGovernance.ProposalState.Cancelled));
    }

    function testPriceObservation() public {
        // Create pool and add initial liquidity
        (PoolId poolId, ) = createPool(
            factory,
            address(token0),
            address(token1),
            FEE,
            INITIAL_SQRT_PRICE
        );

        addLiquidity(
            MockERC20(token0),
            MockERC20(token1),
            router,
            poolId,
            1e18,
            1e18
        );

        // Record initial price using updatePrice
        uint256 price = oracle.updatePrice(poolId);

        // Get the latest observation
        uint256 observationKey = (block.timestamp / oracle.PERIOD()) *
            oracle.PERIOD();
        (
            uint256 timestamp,
            uint256 storedPrice,
            uint256 reserve0,
            uint256 reserve1
        ) = oracle.observations(poolId, observationKey);

        // Verify price and timestamp
        assertEq(
            storedPrice,
            price,
            "Stored price should match recorded price"
        );
        assertEq(
            timestamp,
            block.timestamp,
            "Timestamp should be current block"
        );
    }

    function testConsultPrice() public {
        // Retrieve the existing pool ID from the factory
        PoolId poolId = factory.getPoolId(address(token0), address(token1));

        // Add liquidity to the existing pool
        addLiquidity(
            MockERC20(token0),
            MockERC20(token1),
            router,
            poolId,
            2e18, // 2 tokens of token0
            1e18 // 1 token of token1
        );

        // Update price observations
        oracle.updatePrice(poolId);
        uint256 firstPeriod = block.timestamp / oracle.PERIOD();
        vm.warp(block.timestamp + oracle.PERIOD()); // Move to the next period
        oracle.updatePrice(poolId); // Record price in the new period

        // Consult the price for the previous period
        uint256 price = oracle.consult(poolId, oracle.PERIOD());
        assertGt(price, 0, "Consulted price should be non-zero");
    }

    function testGetReserves() public {
        // Retrieve the existing pool ID from the factory
        PoolId poolId = factory.getPoolId(address(token0), address(token1));

        // Define the amounts to add as liquidity
        uint256 amount0 = 2e18; // Amount of token0
        uint256 amount1 = 1e18; // Amount of token1

        // IMPORTANT: Set the expected BalanceDelta for the mockPoolManager
        // When adding liquidity, tokens move from caller → pool, so from caller's POV the delta is negative.
        // We must cast properly from uint256 → int128.
        int128 delta0 = -int128(int256(amount0));
        int128 delta1 = -int128(int256(amount1));
        mockPoolManager.setNextModifyLiquidityCallerDelta(
            poolId,
            delta0,
            delta1
        );

        // Add liquidity to the existing pool
        addLiquidity(
            MockERC20(token0),
            MockERC20(token1),
            router,
            poolId,
            amount0,
            amount1
        );

        // Record the price observation
        oracle.updatePrice(poolId);

        // Get the reserves from the oracle (which now correctly reads from ReserveTrackingHook)
        (uint256 reserve0, uint256 reserve1, uint256 timestamp) = oracle
            .getReserves(poolId);

        // Verify that the reserves match the added liquidity amounts
        assertEq(reserve0, amount0, "Reserve0 should match added liquidity");
        assertEq(reserve1, amount1, "Reserve1 should match added liquidity");
        assertEq(
            timestamp,
            block.timestamp,
            "Timestamp should be current block"
        );
    }

   function testRevertOnStalePrice() public {
        // 1) Create pool and add initial liquidity
        (PoolId poolId, ) = createPool(
            factory,
            address(token0),
            address(token1),
            FEE,
            INITIAL_SQRT_PRICE
        );

        addLiquidity(
            MockERC20(token0),
            MockERC20(token1),
            router,
            poolId,
            1e18,
            1e18
        );

        // 2) Record a fresh observation - occurs at timestamp 1
        oracle.updatePrice(poolId);
        
        // 3) Advance time beyond PERIOD (3600 seconds)
        vm.warp(block.timestamp + oracle.PERIOD() + 1); // Now at 3602
        
        // 4) Get PERIOD value before expectRevert
        uint256 period = oracle.PERIOD();
        
        // 5) Expect revert with correct parameters
        vm.expectRevert(
            abi.encodeWithSelector(
                CPAMMOracle.StalePrice.selector,
                1,  // Correct observation timestamp
                block.timestamp
            )
        );
        
        // 6) Make the consult call
        oracle.consult(poolId, period);
    }

    function testAddLiquidity() public {
        // Declare and initialize the amounts
        uint256 amount0 = 1000e18;
        uint256 amount1 = 1000e18;

        // Mint tokens to this contract
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);

        // Approve router to spend tokens
        token0.approve(address(router), amount0);
        token1.approve(address(router), amount1);

        // Get the pool ID
        PoolId poolId = factory.getPoolId(address(token0), address(token1));

        // Set expected deltas in mock PoolManager
        mockPoolManager.setNextModifyLiquidityCallerDelta(
            poolId,
            -int128(int256(amount0)),
            -int128(int256(amount1))
        );

        // Add liquidity and capture returned values
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router
            .addLiquidity(
                address(token0),
                address(token1),
                amount0,
                amount1,
                0, // amountAMin
                0, // amountBMin
                address(this),
                block.timestamp
            );

        // Verify results
        assertGt(amountA, 0, "Amount A should be greater than 0");
        assertGt(amountB, 0, "Amount B should be greater than 0");
        assertGt(liquidity, 0, "Liquidity should be greater than 0");
    }

    function testRemoveLiquidity() public {
        // Declare and initialize the amounts
        uint256 amount0 = 1000e18;
        uint256 amount1 = 1000e18;

        // First add liquidity
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        token0.approve(address(liquidityProvider), amount0);
        token1.approve(address(liquidityProvider), amount1);

        // *** you forgot this: seed the mock so your hook sees the deltas! ***
        PoolId pid = factory.getPoolId(address(token0), address(token1));
        int128 d0 = -int128(int256(amount0));
        int128 d1 = -int128(int256(amount1));
        mockPoolManager.setNextModifyLiquidityCallerDelta(pid, d0, d1);

        (uint256 addedA, uint256 addedB, uint256 liquidity) = liquidityProvider
            .addLiquidity(
                address(token0),
                address(token1),
                amount0,
                amount1,
                0, // amountAMin
                0, // amountBMin
                address(this),
                block.timestamp
            );

        // Now remove liquidity
        // Approve liquidityProvider to spend LP tokens
        pair.approve(address(liquidityProvider), liquidity);

        // seed the mock so removeLiquidity sees the right positive deltas
        // (pool “gives back” amount0 and amount1 when you burn your LP)
        mockPoolManager.setNextModifyLiquidityCallerDelta(
         pid,
         int128(int256(amount0)),
         int128(int256(amount1))
        );

        // fund the mockPoolManager so its safeTransfer() will succeed
        token0.mint(address(mockPoolManager), amount0);
        token1.mint(address(mockPoolManager), amount1);

        (uint256 removedA, uint256 removedB) = liquidityProvider
            .removeLiquidity(
                address(token0),
                address(token1),
                liquidity,
                (addedA * 90) / 100, // 90% of original amount as minimum
                (addedB * 90) / 100,
                address(this),
                block.timestamp + 1
            );

        // Verify results
        assertGt(removedA, 0, "Removed amount A should be greater than 0");
        assertGt(removedB, 0, "Removed amount B should be greater than 0");
        assertLe(
            removedA,
            addedA,
            "Removed amount A should not exceed added amount"
        );
        assertLe(
            removedB,
            addedB,
            "Removed amount B should not exceed added amount"
        );
    }
 
    function testSwapExactTokensForTokens() public {
        // Setup initial liquidity
        deal(address(token0), user, 100e18);
        deal(address(token1), user, 100e18);
        vm.startPrank(user);
        token0.approve(address(router), 100e18);
        token1.approve(address(router), 100e18);

        // Set expected deltas in mock PoolManager
        PoolId poolId = factory.getPoolId(address(token0), address(token1));
        mockPoolManager.setNextModifyLiquidityCallerDelta(
            poolId,
            -int128(int256(50e18)), // token0 delta
            -int128(int256(50e18))  // token1 delta
        );

        router.addLiquidity(
            address(token0),
            address(token1),
            50e18,
            50e18,
            45e18,
            45e18,
            user,
            block.timestamp + 1
        );

        // Prepare swap
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);

        uint256 amountIn = 1e18;
        token0.approve(address(router), amountIn);

        // Set expected swap delta
        uint256 expectedOut = 0.5e18; // 50% of input
        mockPoolManager.setNextSwapDelta(
            poolId,
            int128(int256(expectedOut)), // token1 out
            -int128(int256(amountIn))    // token0 in
        );

        // Execute swap
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            0, // amountOutMin
            path,
            user,
            block.timestamp + 1
        );

        // Verify results
        assertGt(amounts[1], 0, "Output amount should be greater than 0");
        vm.stopPrank();
    }

    function testHookRegistration() public {
        // Only the owner can register, so impersonate the owner
        vm.startPrank(owner);

        // Grab the factory’s built‑in reserveHook address
        address hookAddress = address(factory.reserveHook());

        // This should now succeed, because it's exactly the factory's own hook
        factory.registerHook(hookAddress);

        // Verify that the factory accepts it
        assertTrue(
            factory.isHookValid(hookAddress),
            "Hook should be registered"
        );

        vm.stopPrank();
    }

    // Updated revert test cases
    function test_RevertWhen_AddingInsufficientLiquidity() public {
        uint256 amount0 = 1;
        uint256 amount1 = 1;

        vm.startPrank(user1);
        
        // Mint tokens directly to user
        token0.mint(user1, amount0);
        token1.mint(user1, amount1);
        
        // Approve liquidity provider to spend tokens
        token0.approve(address(liquidityProvider), amount0);
        token1.approve(address(liquidityProvider), amount1);
        
        // Expect revert when adding liquidity
        vm.expectRevert(CPAMMLiquidityProvider.InsufficientLiquidityMinted.selector);
        liquidityProvider.addLiquidity(
            address(token0),
            address(token1),
            amount0,
            amount1,
            0,
            0,
            user1,
            block.timestamp + 1
        );
        vm.stopPrank();
    }

    function test_RevertWhen_UnauthorizedUserCreatesProposal() public {
        PoolId poolId = createMockPool(
            factory,
            3000,
            UniswapV4Utils.MIN_SQRT_RATIO
        );
        uint24 newFee = 5000;
        uint256 delay = 1 days;

        vm.expectRevert(CPAMMGovernance.UnauthorizedCaller.selector);
        vm.prank(unauthorizedUser);
        governance.createProposal(poolId, newFee, delay);
    }

    function test_RevertWhen_ProposalWithInvalidFee() public {
        PoolId poolId = createMockPool(
            factory,
            3000,
            UniswapV4Utils.MIN_SQRT_RATIO
        );
        uint24 newFee = 150000;
        uint256 delay = 1 days;

        vm.expectRevert(); // Add specific error if available
        vm.prank(authorizedUser);
        governance.createProposal(poolId, newFee, delay);
    }

    function test_RevertWhen_ProposalExceedsMaxDelay() public {
        PoolId poolId = createMockPool(
            factory,
            3000,
            UniswapV4Utils.MIN_SQRT_RATIO
        );
        uint24 newFee = 5000;
        uint256 delay = 31 days;

        vm.expectRevert(); // Add specific error if available
        vm.prank(authorizedUser);
        governance.createProposal(poolId, newFee, delay);
    }

    function test_RevertWhen_AddLiquidityWithExpiredDeadline() public {
        (address token0, address token1) = setupTokens(user);
        createPool(
            factory,
            address(token0),
            address(token1),
            FEE,
            INITIAL_SQRT_PRICE
        );

        vm.startPrank(user);
        MockERC20(token0).approve(address(liquidityProvider), 1000e18);
        MockERC20(token1).approve(address(liquidityProvider), 1000e18);

        uint256 deadline = block.timestamp - 1;
        vm.expectRevert(
            abi.encodeWithSelector(CPAMMLiquidityProvider.DeadlineExpired.selector, deadline)
        );
        liquidityProvider.addLiquidity(
            token0,
            token1,
            1000e18,
            1000e18,
            900e18,
            900e18,
            user,
            deadline
        );
        vm.stopPrank();
    }

    function test_RevertWhen_AddLiquidityWithoutApproval() public {
        (address token0, address token1) = setupTokens(user);
        createPool(
            factory,
            address(token0),
            address(token1),
            FEE,
            INITIAL_SQRT_PRICE
        );

        vm.startPrank(user);
        
        // Get liquidity provider address
        address lp = address(liquidityProvider);
        
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")),
                lp,
                0,
                1000e18
            )
        );
        liquidityProvider.addLiquidity(
            token0,
            token1,
            1000e18,
            1000e18,
            900e18,
            900e18,
            user,
            block.timestamp + 1
        );
        vm.stopPrank();
    }

    function test_RevertWhen_SwapWithInvalidPath() public {
        vm.startPrank(user);
        address[] memory InvalidPath = new address[](1);
        InvalidPath[0] = address(token0);

        vm.expectRevert(CPAMMRouter.InvalidPath.selector);
        router.swapExactTokensForTokens(
            1e18,
            0,
            InvalidPath,
            user,
            block.timestamp + 1
        );
        vm.stopPrank();
    }

    function test_RevertWhen_AddLiquidityAfterDeadline() public {
        vm.startPrank(user);
        // Mint tokens to user
        token0.mint(user, 50e18);
        token1.mint(user, 50e18);
        // Approve router to spend tokens
        token0.approve(address(router), 50e18);
        token1.approve(address(router), 50e18);

        // Set block.timestamp to 5 (exceeds deadline of 4)
        vm.warp(5);
        vm.expectRevert(abi.encodeWithSelector(CPAMMRouter.DeadlineExpired.selector, 4));
        router.addLiquidity(
            address(token0),
            address(token1),
            50e18,
            50e18,
            45e18,
            45e18,
            user,
            4 // Deadline is in the past
        );
        vm.stopPrank();
    }

    function test_RevertWhen_SwapZeroAmount() public {
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        uint256 deadline = block.timestamp + 1 days;

        vm.expectRevert(CPAMMRouter.InvalidSwapAmount.selector);
        router.swapExactTokensForTokens(0, 0, path, user, deadline);
    }
}
