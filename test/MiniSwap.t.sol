// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MiniSwap} from "../src/MiniSwap.sol";
import {MockToken} from "../src/MockToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MiniSwapTest is Test {
    MiniSwap amm;
    MockToken tokenA; // token0
    MockToken tokenB; // token1

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant INIT = 1000 ether; // initial liquidity per side (price 1:1)
    uint256 constant FIRST_SHARES = 1000 ether - 1000; // sqrt(1e21*1e21) - MINIMUM_LIQUIDITY

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event Swapped(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    function setUp() public {
        tokenA = new MockToken("Token A", "TKA");
        tokenB = new MockToken("Token B", "TKB");
        amm = new MiniSwap(address(tokenA), address(tokenB));

        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob, 1_000_000 ether);
        tokenB.mint(bob, 1_000_000 ether);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        tokenA.approve(address(amm), type(uint256).max);
        tokenB.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    // alice seeds a balanced 1000/1000 pool
    function _seed() internal {
        _approveAll(alice);
        vm.prank(alice);
        amm.addLiquidity(INIT, INIT, 0);
    }

    // --- constructor ---

    function testConstructorRevertsZeroAddress() public {
        vm.expectRevert(MiniSwap.ZeroAddress.selector);
        new MiniSwap(address(0), address(tokenB));
    }

    function testConstructorRevertsIdenticalTokens() public {
        vm.expectRevert(MiniSwap.IdenticalTokens.selector);
        new MiniSwap(address(tokenA), address(tokenA));
    }

    // --- addLiquidity ---

    function testAddFirstMint() public {
        _seed();
        assertEq(amm.balanceOf(alice), FIRST_SHARES, "LP minted to provider");
        assertEq(amm.balanceOf(0x000000000000000000000000000000000000dEaD), 1000, "MINIMUM_LIQUIDITY locked");
        assertEq(amm.totalSupply(), INIT);
        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(r0, INIT);
        assertEq(r1, INIT);
        assertEq(tokenA.balanceOf(address(amm)), INIT);
    }

    function testAddFirstMintEmits() public {
        _approveAll(alice);
        vm.expectEmit(true, false, false, true, address(amm));
        emit LiquidityAdded(alice, INIT, INIT, FIRST_SHARES);
        vm.prank(alice);
        amm.addLiquidity(INIT, INIT, 0);
    }

    function testAddSubsequentKeepsRatio() public {
        _seed();
        _approveAll(bob);
        vm.prank(bob);
        uint256 shares = amm.addLiquidity(500 ether, 500 ether, 0);
        assertEq(shares, 500 ether, "proportional shares");
        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(r0, 1500 ether);
        assertEq(r1, 1500 ether);
    }

    function testAddUnbalancedUsesToken1Optimal() public {
        _seed();
        _approveAll(bob);
        uint256 bBefore = tokenB.balanceOf(bob);
        vm.prank(bob);
        // wants 500 A + 1000 B, but ratio is 1:1 -> only 500 B is pulled
        amm.addLiquidity(500 ether, 1000 ether, 0);
        assertEq(tokenB.balanceOf(bob), bBefore - 500 ether, "only the matching token1 amount is pulled");
    }

    function testAddUnbalancedUsesToken0Optimal() public {
        _seed();
        _approveAll(bob);
        uint256 aBefore = tokenA.balanceOf(bob);
        vm.prank(bob);
        // wants 1000 A + 500 B, ratio 1:1 -> only 500 A is pulled
        amm.addLiquidity(1000 ether, 500 ether, 0);
        assertEq(tokenA.balanceOf(bob), aBefore - 500 ether, "only the matching token0 amount is pulled");
    }

    function testAddRevertsZeroAmount() public {
        _approveAll(alice);
        vm.prank(alice);
        vm.expectRevert(MiniSwap.ZeroAmount.selector);
        amm.addLiquidity(0, INIT, 0);
    }

    function testAddRevertsTinyFirstDeposit() public {
        _approveAll(alice);
        vm.prank(alice);
        // sqrt(1000 * 1000) = 1000 <= MINIMUM_LIQUIDITY -> reverts cleanly
        vm.expectRevert(MiniSwap.InsufficientLiquidityMinted.selector);
        amm.addLiquidity(1000, 1000, 0);
    }

    function testAddRevertsSlippageMinShares() public {
        _approveAll(alice);
        vm.prank(alice);
        vm.expectRevert(MiniSwap.InsufficientLiquidityMinted.selector);
        amm.addLiquidity(INIT, INIT, FIRST_SHARES + 1); // demands more LP than possible
    }

    function testAddRevertsWithoutApproval() public {
        vm.prank(alice); // no approve
        vm.expectRevert();
        amm.addLiquidity(INIT, INIT, 0);
    }

    function testAddRecordsActualReceivedForFeeToken() public {
        FeeToken fee = new FeeToken(1000); // 10% transfer fee, as token0
        MiniSwap pool = new MiniSwap(address(fee), address(tokenB));
        fee.mint(alice, INIT);

        vm.startPrank(alice);
        fee.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(INIT, INIT, 0);
        vm.stopPrank();

        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 900 ether, "reserve0 = actually received (after the 10% fee), not requested");
        assertEq(r1, INIT);
    }

    function testAddRevertsWhenNothingReceived() public {
        FeeToken fee = new FeeToken(10_000); // 100% fee -> pool receives nothing
        MiniSwap pool = new MiniSwap(address(fee), address(tokenB));
        fee.mint(alice, INIT);

        vm.startPrank(alice);
        fee.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.expectRevert(MiniSwap.ZeroAmount.selector);
        pool.addLiquidity(INIT, INIT, 0);
        vm.stopPrank();
    }

    // --- removeLiquidity ---

    function testRemoveLiquidity() public {
        _seed();
        uint256 shares = amm.balanceOf(alice); // FIRST_SHARES
        uint256 aBefore = tokenA.balanceOf(alice);
        uint256 bBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = amm.removeLiquidity(shares, 0, 0);

        // gets back proportional amounts (the locked MINIMUM_LIQUIDITY stays behind)
        assertEq(a0, INIT - 1000);
        assertEq(a1, INIT - 1000);
        assertEq(tokenA.balanceOf(alice), aBefore + a0);
        assertEq(tokenB.balanceOf(alice), bBefore + a1);
        assertEq(amm.balanceOf(alice), 0);
    }

    function testRemoveEmits() public {
        _seed();
        uint256 shares = amm.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(amm));
        emit LiquidityRemoved(alice, INIT - 1000, INIT - 1000, shares);
        vm.prank(alice);
        amm.removeLiquidity(shares, 0, 0);
    }

    function testRemoveRevertsZero() public {
        _seed();
        vm.prank(alice);
        vm.expectRevert(MiniSwap.ZeroAmount.selector);
        amm.removeLiquidity(0, 0, 0);
    }

    function testRemoveRevertsSlippage() public {
        _seed();
        uint256 shares = amm.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MiniSwap.SlippageExceeded.selector);
        amm.removeLiquidity(shares, INIT, INIT); // expects full INIT but gets INIT - 1000
    }

    function testRemoveRevertsWhenBurnsZero() public {
        // pool with a tiny token1 reserve -> removing 1 share rounds token1 out to 0
        _approveAll(alice);
        vm.startPrank(alice);
        amm.addLiquidity(1000 ether, 2000, 0);
        vm.expectRevert(MiniSwap.InsufficientLiquidityBurned.selector);
        amm.removeLiquidity(1, 0, 0);
        vm.stopPrank();
    }

    function testRemoveRevertsIfNotEnoughLP() public {
        _seed();
        vm.prank(bob); // bob holds no LP
        vm.expectRevert(); // ERC20InsufficientBalance
        amm.removeLiquidity(1 ether, 0, 0);
    }

    // --- swap ---

    function testSwapToken0ForToken1() public {
        _seed();
        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 amountIn = 100 ether;
        uint256 expected = amm.getAmountOut(amountIn, r0, r1);

        _approveAll(bob);
        uint256 bBefore = tokenB.balanceOf(bob);
        vm.prank(bob);
        uint256 out = amm.swap(address(tokenA), amountIn, 0);

        assertEq(out, expected);
        assertEq(tokenB.balanceOf(bob) - bBefore, expected);
        (uint256 nr0, uint256 nr1) = amm.getReserves();
        assertEq(nr0, r0 + amountIn);
        assertEq(nr1, r1 - expected);
    }

    function testSwapToken1ForToken0() public {
        _seed();
        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 amountIn = 100 ether;
        uint256 expected = amm.getAmountOut(amountIn, r1, r0); // token1 in, token0 out

        _approveAll(bob);
        uint256 aBefore = tokenA.balanceOf(bob);
        vm.prank(bob);
        uint256 out = amm.swap(address(tokenB), amountIn, 0);

        assertEq(out, expected);
        assertEq(tokenA.balanceOf(bob) - aBefore, expected);
    }

    function testSwapEmits() public {
        _seed();
        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 amountIn = 100 ether;
        uint256 expected = amm.getAmountOut(amountIn, r0, r1);
        _approveAll(bob);
        vm.expectEmit(true, true, false, true, address(amm));
        emit Swapped(bob, address(tokenA), amountIn, expected);
        vm.prank(bob);
        amm.swap(address(tokenA), amountIn, 0);
    }

    function testSwapGrowsK() public {
        _seed();
        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 kBefore = r0 * r1;
        _approveAll(bob);
        vm.prank(bob);
        amm.swap(address(tokenA), 100 ether, 0);
        (uint256 nr0, uint256 nr1) = amm.getReserves();
        assertGe(nr0 * nr1, kBefore, "the 0.3% fee makes k grow");
    }

    function testSwapRevertsZero() public {
        _seed();
        _approveAll(bob);
        vm.prank(bob);
        vm.expectRevert(MiniSwap.ZeroAmount.selector);
        amm.swap(address(tokenA), 0, 0);
    }

    function testSwapRevertsInvalidToken() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(MiniSwap.InvalidToken.selector);
        amm.swap(makeAddr("random"), 100 ether, 0);
    }

    function testSwapRevertsSlippage() public {
        _seed();
        _approveAll(bob);
        vm.prank(bob);
        vm.expectRevert(MiniSwap.SlippageExceeded.selector);
        amm.swap(address(tokenA), 100 ether, 100 ether); // out is < 100 due to fee + curve
    }

    function testSwapRevertsNoLiquidity() public {
        // fresh pool, never seeded
        _approveAll(bob);
        vm.prank(bob);
        vm.expectRevert(MiniSwap.NoLiquidity.selector);
        amm.swap(address(tokenA), 100 ether, 0);
    }

    // --- getAmountOut ---

    function testGetAmountOutZeroCases() public view {
        assertEq(amm.getAmountOut(0, 1000, 1000), 0);
        assertEq(amm.getAmountOut(100, 0, 1000), 0);
        assertEq(amm.getAmountOut(100, 1000, 0), 0);
    }

    // --- security / invariants ---

    function testFirstDepositorLockIsInPlace() public {
        _seed();
        // the first MINIMUM_LIQUIDITY is locked at the dead address -> can't be removed,
        // which neutralises the first-depositor share-inflation attack.
        assertEq(amm.balanceOf(0x000000000000000000000000000000000000dEaD), 1000);
    }

    function testFuzzKNeverDecreasesOnSwap(uint256 amountIn, bool zeroForOne) public {
        _seed();
        amountIn = bound(amountIn, 1e12, 100_000 ether); // above dust, so output is always > 0
        address tokenIn = zeroForOne ? address(tokenA) : address(tokenB);

        (uint256 r0, uint256 r1) = amm.getReserves();
        uint256 kBefore = r0 * r1;

        MockToken(tokenIn).mint(bob, amountIn);
        vm.startPrank(bob);
        MockToken(tokenIn).approve(address(amm), amountIn);
        amm.swap(tokenIn, amountIn, 0);
        vm.stopPrank();

        (uint256 nr0, uint256 nr1) = amm.getReserves();
        assertGe(nr0 * nr1, kBefore, "k must never decrease on a swap");
    }

    function testFuzzAddThenRemoveRoundtrips(uint256 amount) public {
        _seed();
        amount = bound(amount, 1 ether, 500_000 ether);

        _approveAll(bob);
        vm.startPrank(bob);
        uint256 shares = amm.addLiquidity(amount, amount, 0);
        uint256 aBefore = tokenA.balanceOf(bob);
        uint256 bBefore = tokenB.balanceOf(bob);
        (uint256 a0, uint256 a1) = amm.removeLiquidity(shares, 0, 0);
        vm.stopPrank();

        // adding then immediately removing returns essentially the deposit (minus tiny rounding)
        assertApproxEqAbs(a0, amount, 1e6, "token0 roundtrip");
        assertApproxEqAbs(a1, amount, 1e6, "token1 roundtrip");
        assertEq(tokenA.balanceOf(bob), aBefore + a0);
        assertEq(tokenB.balanceOf(bob), bBefore + a1);
    }
}

/// @dev ERC-20 that charges a fee on every transfer, to test fee-on-transfer accounting.
contract FeeToken is ERC20 {
    uint256 private immutable _feeBps;

    constructor(uint256 feeBps_) ERC20("Fee", "FEE") {
        _feeBps = feeBps_;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function _update(address from_, address to_, uint256 value_) internal override {
        if (from_ == address(0) || to_ == address(0)) {
            super._update(from_, to_, value_); // no fee on mint / burn
            return;
        }
        uint256 fee = (value_ * _feeBps) / 10_000;
        super._update(from_, to_, value_ - fee);
        super._update(from_, address(0xdEaD), fee);
    }
}
