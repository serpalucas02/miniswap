// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MiniSwap} from "../src/MiniSwap.sol";
import {MockToken} from "../src/MockToken.sol";

contract Deploy is Script {
    uint256 constant SEED = 100_000 ether; // initial liquidity so the demo pool is usable right away

    function run() external returns (MiniSwap amm, MockToken tokenA, MockToken tokenB) {
        vm.startBroadcast();
        tokenA = new MockToken("MiniSwap Token A", "MTA");
        tokenB = new MockToken("MiniSwap Token B", "MTB");
        amm = new MiniSwap(address(tokenA), address(tokenB));

        // Seed a balanced pool from the deployer.
        tokenA.mint(msg.sender, SEED);
        tokenB.mint(msg.sender, SEED);
        tokenA.approve(address(amm), SEED);
        tokenB.approve(address(amm), SEED);
        amm.addLiquidity(SEED, SEED, 0);

        vm.stopBroadcast();
    }
}
