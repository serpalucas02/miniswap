// Deployed on Ethereum Sepolia. token0 = TKA, token1 = TKB (both 18-decimal test tokens).
export const MINISWAP_ADDRESS = "0x34c2b149BF5a7783BAC817Db8ad7b880C5531CfC" as const;
export const TOKEN0_ADDRESS = "0x5fAdd5c1F2B79dad290ca47A9284046Ec8Ffa579" as const;
export const TOKEN1_ADDRESS = "0x126CE9B37c5CA1F7c102D962BE2D47be48A31e43" as const;

export const TOKEN0_SYMBOL = "TKA";
export const TOKEN1_SYMBOL = "TKB";
export const DECIMALS = 18;

export const miniSwapAbi = [
  {
    type: "function",
    name: "addLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amount0Desired", type: "uint256" },
      { name: "amount1Desired", type: "uint256" },
      { name: "minShares", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "removeLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "minAmount0", type: "uint256" },
      { name: "minAmount1", type: "uint256" },
    ],
    outputs: [
      { type: "uint256" },
      { type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "swap",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getReserves",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "uint256" },
      { type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const tokenAbi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to_", type: "address" },
      { name: "amount_", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;
