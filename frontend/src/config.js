import deployed from "./deployed.json";
const env = import.meta.env;
const ZERO = "0x0000000000000000000000000000000000000000";
export const ADDR = {
  token: env.VITE_TCH8_ADDRESS || deployed.token || ZERO,
  sale: env.VITE_SALE_ADDRESS || deployed.sale || ZERO,
  escrow: env.VITE_ESCROW_ADDRESS || deployed.escrow || ZERO,
};
export const CONFIGURED = Object.values(ADDR).every((a) => a !== ZERO);
export const CHAIN_ID = 11155111; // Sepolia
export const RPC_URL = env.VITE_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com";
