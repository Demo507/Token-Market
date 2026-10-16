import { createContext, useContext, useState, useEffect, useMemo, useCallback } from "react";
import { BrowserProvider, Contract, JsonRpcProvider } from "ethers";
import { ADDR, CHAIN_ID, RPC_URL } from "./config";
import { TOKEN_ABI, SALE_ABI, ESCROW_ABI } from "./abi";

// Reads go through our own RPC (not the wallet's) so the page loads fast and never hits wallet rate limits.
export const reader = new JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
const READ = {
  token: new Contract(ADDR.token, TOKEN_ABI, reader),
  sale: new Contract(ADDR.sale, SALE_ABI, reader),
  escrow: new Contract(ADDR.escrow, ESCROW_ABI, reader),
};

const ERR = {
  OnlyGovernanceError: "Only the admin wallet can do this.",
  OnlyOperatorError: "Only the operator wallet can do this.",
  SelfPurchaseError: "You can't buy your own item.",
  ItemInactiveError: "This item is no longer for sale.",
  SoldOutError: "Sold out. Someone just bought the last one.",
  WrongStatusError: "This order isn't in the right step for that action.",
  NotBuyerError: "Only the buyer can do this.",
  NotSellerError: "Only the seller can do this.",
  OnlyMinterError: "Contract is not set up as a minter. The admin must run addMinter for the Sale and Escrow contracts.",
  EnforcedPause: "TCH8 transfers are paused by the admin.",
  ERC20InsufficientBalance: "You don't have enough TCH8.",
  ERC20InsufficientAllowance: "Approval is missing. Try again and approve TCH8 first.",
  WindowNotElapsedError: "The auto-confirm window hasn't passed yet.",
  ZeroAmountError: "Amount is too small.",
  MaxSupplyExceededError: "TCH8 max supply reached.",
};

export function friendlyError(e) {
  if (e?.code === "ACTION_REJECTED" || e?.info?.error?.code === 4001) return "You rejected the request in your wallet.";
  if (e?.revert?.name) return ERR[e.revert.name] || e.revert.name;
  if (/insufficient funds/i.test(e?.shortMessage || e?.message || "")) return "Not enough Sepolia ETH to pay the network fee.";
  return e?.reason || e?.shortMessage || e?.message || "Something went wrong.";
}

export const wait = async (p) => { const t = await p; await t.wait(); };

const Ctx = createContext(null);
export const useWallet = () => useContext(Ctx);

export function WalletProvider({ children }) {
  const [s, setS] = useState({ account: null, chainId: null, provider: null, signer: null, raw: null });
  const [error, setError] = useState("");
  const [toast, setToast] = useState(null);
  const [busy, setBusy] = useState(false);

  const notify = useCallback((msg, type = "info") => {
    setToast({ msg, type, id: Date.now() });
    if (type !== "info") setTimeout(() => setToast((t) => (t && t.msg === msg ? null : t)), 7000);
  }, []);

  const attach = useCallback(async (raw, request = true) => {
    const provider = new BrowserProvider(raw, "any");
    const accounts = await provider.send(request ? "eth_requestAccounts" : "eth_accounts", []);
    if (!accounts.length) return;
    const net = await provider.getNetwork();
    const signer = await provider.getSigner();
    raw.on?.("accountsChanged", () => window.location.reload());
    raw.on?.("chainChanged", () => window.location.reload());
    setS({ account: await signer.getAddress(), chainId: Number(net.chainId), provider, signer, raw });
  }, []);

  useEffect(() => { if (window.ethereum) attach(window.ethereum, false).catch(() => {}); }, [attach]);

  const connectInjected = async () => {
    setError("");
    try {
      if (!window.ethereum) throw new Error("No browser wallet found. On a phone, use the "Open in the MetaMask app" button. On a computer, install the MetaMask extension.");
      await attach(window.ethereum, true);
    } catch (e) { setError(friendlyError(e)); }
  };

  const disconnect = async () => { try { await s.raw?.disconnect?.(); } catch {} setS({ account: null, chainId: null, provider: null, signer: null, raw: null }); };

  const switchNetwork = async () => {
    try {
      await s.raw.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0xaa36a7" }] });
    } catch (e) {
      if (e?.code === 4902 || /unrecognized|not added/i.test(e?.message || "")) {
        await s.raw.request({ method: "wallet_addEthereumChain", params: [{ chainId: "0xaa36a7", chainName: "Sepolia", nativeCurrency: { name: "Sepolia ETH", symbol: "ETH", decimals: 18 }, rpcUrls: [RPC_URL], blockExplorerUrls: ["https://sepolia.etherscan.io"] }] });
      } else setError(friendlyError(e));
    }
  };

  const c = useMemo(() => {
    const w = s.signer && s.chainId === CHAIN_ID;
    return {
      ...READ,
      tokenW: w ? new Contract(ADDR.token, TOKEN_ABI, s.signer) : null,
      saleW: w ? new Contract(ADDR.sale, SALE_ABI, s.signer) : null,
      escrowW: w ? new Contract(ADDR.escrow, ESCROW_ABI, s.signer) : null,
    };
  }, [s.signer, s.chainId]);

  const run = useCallback(async (fn, okMsg = "Done") => {
    setBusy(true);
    try { await fn(); notify(okMsg, "ok"); return true; }
    catch (e) { console.error(e); notify(friendlyError(e), "err"); return false; }
    finally { setBusy(false); }
  }, [notify]);

  const value = { ...s, c, error, toast, busy, notify, run, connectInjected, disconnect, switchNetwork };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
