import { useState } from "react";
import { formatEther } from "ethers";
import { WalletProvider, useWallet } from "./wallet";
import { useMarket } from "./data";
import { CONFIGURED, CHAIN_ID } from "./config";
import { Market, Sell, WalletTab, IncomingOrders, MyOrders, MySales, Exchange, SalesFeed, Admin, Complaints, Disputes, soldOrders, fmt, short, same } from "./views";

function Landing() {
  const w = useWallet();
  const host = typeof window !== "undefined" ? window.location.host + window.location.pathname : "";
  return (
    <div className="landing">
      <div className="block hero">
        <h1>TCH8 Market</h1>
        <p>Buy and sell with TCH8. Every order is held in escrow until the buyer confirms delivery.</p>
        <p className="mute">Connect your wallet on Sepolia to enter.</p>
        <div className="stack">
          <button className="btn big" onClick={w.connectInjected}>Connect wallet</button>
          <a className="btn ghost big" href={`https://metamask.app.link/dapp/${host}`}>Open in the MetaMask app</a>
        </div>
        {w.error && <div className="alert">{w.error}</div>}
      </div>
    </div>
  );
}

function Stats({ m }) {
  const circulating = m.supply > m.locked ? m.supply - m.locked : 0n;
  const cells = [
    ["Your TCH8 balance", fmt(m.balance), "gold"],
    ["Total supply", fmt(m.supply)],
    ["In circulation", fmt(circulating)],
    ["Locked in escrow", fmt(m.locked)],
    ["Max supply cap", fmt(m.maxSupply)],
  ];
  return (
    <section className="stats" aria-label="TCH8 supply">
      {cells.map(([label, value, tone]) => (
        <div className={`block stat ${tone || ""}`} key={label}><span>{label}</span><b>{value}</b></div>))}
    </section>
  );
}

function Ticker({ m }) {
  const buys = m.purchases.map((p) => ({ t: p.time, kind: "bought", tag: "TCH8 BOUGHT", text: `${short(p.buyer)} bought ${fmt(p.tokensOut)} TCH8 for ${Number(formatEther(p.ethPaid))} ETH` }));
  const sales = soldOrders(m).map((o) => {
    const it = m.items.find((i) => i.id === o.itemId);
    return { t: o.confirmedAt, kind: "sold", tag: "SALE", text: `${short(o.buyer)} bought ${it ? `"${it.title}"` : "an item"} from ${short(o.seller)} for ${fmt(o.amount)} TCH8` };
  });
  const listings = m.items.map((i) => ({ t: i.createdAt, kind: "listed", tag: "NEW LISTING", text: `${short(i.seller)} listed "${i.title}" for ${fmt(i.price)} TCH8 (${i.quantity} available)` }));
  const feed = [...buys, ...sales, ...listings].sort((a, b) => b.t - a.t).slice(0, 30);
  const line = feed.length ? feed : [{ t: 0, kind: "info", tag: "LIVE", text: "No activity yet. Buy TCH8 in the Wallet tab or list the first item." }];
  return (
    <div className="ticker" aria-label="Latest marketplace activity">
      <div className="track">{[...line, ...line].map((f, i) => <span key={i}><b className={`tag ${f.kind}`}>{f.tag}</b>{f.text}</span>)}</div>
    </div>
  );
}

const TABS = [["market", "Market"], ["sell", "Sell"], ["wallet", "Wallet"], ["orders", "Orders"], ["my-orders", "My Orders"], ["my-sales", "My Sales"], ["exchange", "Exchange"], ["sales", "Sales"], ["complaints", "Complaints"], ["disputes", "Disputes"], ["admin", "Admin"]];

function Shell() {
  const w = useWallet();
  const m = useMarket();
  const [tab, setTab] = useState("market");
  const isAdmin = [m.roles.saleGov, m.roles.escGov, m.roles.op].some((a) => same(a, w.account));
  const count = {
    orders: m.orders.filter((o) => same(o.seller, w.account) && o.status === 1).length,
    "my-orders": m.orders.filter((o) => same(o.buyer, w.account) && o.status === 2).length,
    "my-sales": m.orders.filter((o) => same(o.seller, w.account) && o.status === 3).length,
    disputes: same(w.account, m.roles.escGov) ? m.disputes.filter((d) => d.resolvedAt === 0).length : 0,
    admin: same(w.account, m.roles.escGov) ? m.tickets.filter((t) => t.repliedAt === 0).length : 0,
  };
  const tabs = TABS.filter(([k]) => k !== "admin" || isAdmin);
  const View = { market: Market, sell: Sell, wallet: WalletTab, orders: IncomingOrders, "my-orders": MyOrders, "my-sales": MySales, exchange: Exchange, sales: SalesFeed, complaints: Complaints, disputes: Disputes, admin: Admin }[tab];

  return (
    <>
      <header className="top">
        <div className="logo">TCH8 Market</div>
        <div className="who">
          <span className="chip gold">{fmt(m.balance)} TCH8</span>
          <span className="chip">{short(w.account)}</span>
          <button className="btn ghost sm" onClick={w.disconnect}>Disconnect</button>
        </div>
      </header>
      <Stats m={m} />
      <Ticker m={m} />
      <nav className="tabs">{tabs.map(([k, label]) => (
        <button key={k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>{label}{count[k] > 0 && <i>{count[k]}</i>}</button>))}</nav>
      <main>
        {m.error && <div className="alert">{m.error}</div>}
        {m.loading ? <div className="block empty">Loading the market…</div> : <View m={m} />}
      </main>
    </>
  );
}

function Gate() {
  const w = useWallet();
  if (!w.account) return <Landing />;
  if (w.chainId !== CHAIN_ID) return (
    <div className="landing"><div className="block hero">
      <h1>Switch to Sepolia</h1><p>This app runs on the Sepolia test network.</p>
      <button className="btn big" onClick={w.switchNetwork}>Switch network</button>
      {w.error && <div className="alert">{w.error}</div>}
    </div></div>);
  if (!CONFIGURED) return (
    <div className="landing"><div className="block hero">
      <h1>Contracts not set</h1>
      <p>Add the deployed addresses to <code>src/deployed.json</code> or set VITE_TCH8_ADDRESS, VITE_SALE_ADDRESS and VITE_ESCROW_ADDRESS, then redeploy.</p>
    </div></div>);
  return <Shell />;
}

function Toast() {
  const { toast } = useWallet();
  return toast ? <div className={`toast ${toast.type}`} role="status">{toast.msg}</div> : null;
}

export default function App() {
  return <WalletProvider><Gate /><Toast /></WalletProvider>;
}
