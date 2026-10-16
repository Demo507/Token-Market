import { useEffect, useState } from "react";
import { formatUnits, formatEther, parseUnits, parseEther, isAddress, getAddress } from "ethers";
import { useWallet, wait, reader } from "./wallet";
import { ADDR } from "./config";

export const fmt = (v) => Number(formatUnits(v, 6)).toLocaleString(undefined, { maximumFractionDigits: 6 });
export const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "");
export const when = (t) => (t ? new Date(t * 1000).toLocaleString() : "—");
export const same = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
export const STATUS = ["None", "Paid, awaiting delivery", "Delivered, awaiting buyer", "Confirmed, ready to redeem", "Redeemed", "Refunded", "Disputed"];
const RSTATUS = ["None", "Pending", "Paid out", "Rejected, refunded"];

async function ensureAllowance(w, amount) {
  const have = await w.c.token.allowance(w.account, ADDR.escrow);
  if (have < amount) {
    w.notify("Step 1 of 2: approve TCH8 in your wallet…");
    await wait(w.c.tokenW.approve(ADDR.escrow, amount));
  }
}
const Empty = ({ children }) => <div className="block empty">{children}</div>;

// Images are stored per item on-chain; load each one once, only when its card is shown.
const imgCache = new Map();
function useImage(id) {
  const { c } = useWallet();
  const [src, setSrc] = useState(imgCache.get(id) ?? null);
  useEffect(() => {
    if (imgCache.has(id)) { setSrc(imgCache.get(id)); return; }
    let on = true;
    c.escrow.itemImage(id).then((v) => { imgCache.set(id, v); if (on) setSrc(v); }).catch(() => {});
    return () => { on = false; };
  }, [id, c]);
  return src && /^(data:image\/|https?:\/\/)/.test(src) ? src : null;
}

function Thumb({ it }) {
  const src = useImage(it.id);
  const [bad, setBad] = useState(false);
  return <div className="thumb">{src && !bad ? <img src={src} alt="" onError={() => setBad(true)} /> : <span>{it.title.slice(0, 1).toUpperCase()}</span>}</div>;
}

// Shrinks a chosen photo so it is small enough to store on-chain (about 9 KB max).
async function compressImage(file, maxChars = 9000) {
  const bmp = await createImageBitmap(file);
  for (const side of [320, 260, 220, 180, 140]) {
    const scale = Math.min(1, side / Math.max(bmp.width, bmp.height));
    const cv = document.createElement("canvas");
    cv.width = Math.max(1, Math.round(bmp.width * scale));
    cv.height = Math.max(1, Math.round(bmp.height * scale));
    const ctx = cv.getContext("2d");
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, cv.width, cv.height);
    ctx.drawImage(bmp, 0, 0, cv.width, cv.height);
    for (const q of [0.7, 0.55, 0.4]) {
      const url = cv.toDataURL("image/jpeg", q);
      if (url.length <= maxChars) return url;
    }
  }
  throw new Error("That photo is too detailed to store. Pick a simpler one or paste an image link instead.");
}

/* ---------------- Market ---------------- */
export function Market({ m }) {
  const w = useWallet();
  const items = m.items.filter((i) => i.active && i.quantity > 0).slice().reverse();
  const buy = (it) => w.run(async () => {
    const bal = await w.c.token.balanceOf(w.account);
    if (bal < it.price) throw new Error(`Not enough TCH8. You hold ${fmt(bal)} and this costs ${fmt(it.price)}. Get TCH8 in the Wallet tab.`);
    await ensureAllowance(w, it.price);
    w.notify("Step 2 of 2: confirm the order in your wallet…");
    await wait(w.c.escrowW.createOrder(it.id));
    await m.refresh();
  }, "Order placed. Your TCH8 is now held in escrow.");

  if (!items.length) return <Empty>No items for sale yet. Open the Sell tab to list the first one.</Empty>;
  return (
    <div className="grid">
      {items.map((it) => (
        <div className="block item" key={it.id}>
          <Thumb it={it} />
          <h3>{it.title}</h3>
          <p className="mute clamp">{it.description || "No description."}</p>
          <div className="row"><span className="price">{fmt(it.price)} TCH8</span><span className="badge s1">{it.quantity} left</span></div>
          <div className="mute small">Seller {short(it.seller)}</div>
          {same(it.seller, w.account)
            ? <button className="btn ghost" disabled>Your listing</button>
            : <button className="btn" disabled={w.busy} onClick={() => buy(it)}>Buy</button>}
        </div>
      ))}
    </div>
  );
}

function AddStock({ it, m }) {
  const w = useWallet();
  const [n, setN] = useState("1");
  const add = () => w.run(async () => {
    const x = Number(n);
    if (!Number.isInteger(x) || x < 1) throw new Error("Enter a whole number of 1 or more.");
    await wait(w.c.escrowW.addStock(it.id, BigInt(x)));
    await m.refresh();
  }, "Stock added.");
  return <div className="inline"><input className="mini" inputMode="numeric" value={n} onChange={(e) => setN(e.target.value)} /><button className="btn ghost sm" disabled={w.busy} onClick={add}>Add stock</button></div>;
}

/* ---------------- Sell ---------------- */
export function Sell({ m }) {
  const w = useWallet();
  const [f, setF] = useState({ title: "", description: "", price: "", quantity: "1", image: "" });
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value });
  const [fileKey, setFileKey] = useState(0);
  const pick = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    try { setF((x) => ({ ...x, image: "" })); const url = await compressImage(file); setF((x) => ({ ...x, image: url })); }
    catch (err) { w.notify(err.message?.startsWith("That photo") ? err.message : "Could not read that image. Try a JPG or PNG.", "err"); setFileKey((k) => k + 1); }
  };
  const mine = m.items.filter((i) => same(i.seller, w.account)).reverse();

  const submit = () => w.run(async () => {
    if (!f.title.trim()) throw new Error("Enter a title.");
    if (!(Number(f.price) > 0)) throw new Error("Enter a price above 0.");
    const qty = Number(f.quantity);
    if (!Number.isInteger(qty) || qty < 1) throw new Error("Quantity must be a whole number of 1 or more.");
    await wait(w.c.escrowW.listItem(f.title.trim(), f.description.trim(), f.image.trim(), parseUnits(f.price, 6), BigInt(qty)));
    setF({ title: "", description: "", price: "", quantity: "1", image: "" });
    setFileKey((k) => k + 1);
    await m.refresh();
  }, "Item listed.");
  const toggle = (it) => w.run(async () => { await wait(w.c.escrowW.setItemActive(it.id, !it.active)); await m.refresh(); }, it.active ? "Item removed from the market." : "Item is live again.");

  return (
    <div className="two">
      <div className="block form">
        <h3>List an item</h3>
        <label>Title<input value={f.title} onChange={set("title")} maxLength={120} /></label>
        <label>Description<textarea rows={4} value={f.description} onChange={set("description")} maxLength={1000} /></label>
        <label>Price (TCH8)<input inputMode="decimal" value={f.price} onChange={set("price")} placeholder="10" /></label>
        <label>Quantity available<input inputMode="numeric" value={f.quantity} onChange={set("quantity")} placeholder="1" /></label>
        <label>Photo (optional)<input key={fileKey} type="file" accept="image/*" onChange={pick} /></label>
        {f.image.startsWith("data:") && (
          <div className="preview-img">
            <img src={f.image} alt="Chosen photo" />
            <button type="button" className="btn ghost sm" onClick={() => { setF({ ...f, image: "" }); setFileKey((k) => k + 1); }}>Remove photo</button>
          </div>)}
        <label>Or paste an image link (optional)<input value={f.image.startsWith("data:") ? "" : f.image} onChange={set("image")} placeholder="https://…" /></label>
        <button className="btn" disabled={w.busy} onClick={submit}>List item</button>
      </div>
      <div className="stack">
        <h3 className="sec">Your listings</h3>
        {!mine.length && <Empty>You haven't listed anything yet.</Empty>}
        {mine.map((it) => (
          <div className="block stack" key={it.id}>
            <div className="row">
              <div><b>{it.title}</b><div className="mute small">{fmt(it.price)} TCH8 · {it.quantity} in stock · {!it.active ? "Hidden" : it.quantity > 0 ? "Live" : "Sold out"}</div></div>
              <button className="btn ghost sm" disabled={w.busy} onClick={() => toggle(it)}>{it.active ? "Remove" : "Relist"}</button>
            </div>
            <AddStock it={it} m={m} />
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------- Wallet ---------------- */
export function WalletTab({ m }) {
  const w = useWallet();
  const [eth, setEth] = useState("");
  const [to, setTo] = useState("");
  const [amt, setAmt] = useState("");
  let out = 0n;
  try { if (eth && m.price > 0n) out = (parseEther(eth) * 1000000n) / m.price; } catch {}
  const ethPer = Number(formatEther(m.price));

  const buy = () => w.run(async () => { await wait(w.c.saleW.buy({ value: parseEther(eth) })); setEth(""); await m.refresh(); }, "TCH8 added to your wallet.");
  const send = () => w.run(async () => {
    if (!isAddress(to)) throw new Error("That recipient address isn't valid.");
    if (!(Number(amt) > 0)) throw new Error("Enter an amount above 0.");
    await wait(w.c.tokenW.transfer(getAddress(to), parseUnits(amt, 6)));
    setTo(""); setAmt(""); await m.refresh();
  }, "TCH8 sent.");

  return (
    <div className="two">
      <div className="block form">
        <h3>Buy TCH8 with ETH</h3>
        <p className="mute">Rate: 1 ETH = {(1 / ethPer).toLocaleString(undefined, { maximumFractionDigits: 8 })} TCH8 · 1 TCH8 = {ethPer.toLocaleString()} ETH</p>
        <label>ETH to pay<input inputMode="decimal" value={eth} onChange={(e) => setEth(e.target.value)} placeholder="0.01" /></label>
        <div className="preview">You receive <b>{fmt(out)} TCH8</b></div>
        <button className="btn" disabled={w.busy || out === 0n} onClick={buy}>Buy TCH8</button>
      </div>
      <div className="block form">
        <h3>Send TCH8</h3>
        <p className="mute">Your balance: {fmt(m.balance)} TCH8</p>
        <label>Recipient address<input value={to} onChange={(e) => setTo(e.target.value)} placeholder="0x…" /></label>
        <label>Amount (TCH8)<input inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} /></label>
        <button className="btn" disabled={w.busy} onClick={send}>Send TCH8</button>
      </div>
    </div>
  );
}

/* ---------------- Orders ---------------- */
function OrderCard({ o, m, children }) {
  const it = m.items.find((i) => i.id === o.itemId);
  return (
    <div className="block order">
      <div className="row"><b>#{o.id} {it ? it.title : `Item ${o.itemId}`}</b><span className={`badge s${o.status}`}>{STATUS[o.status]}</span></div>
      <div className="kv"><span>Amount</span><b>{fmt(o.amount)} TCH8</b></div>
      <div className="kv"><span>Buyer</span><b>{short(o.buyer)}</b></div>
      <div className="kv"><span>Seller</span><b>{short(o.seller)}</b></div>
      <div className="kv"><span>Placed</span><b>{when(o.createdAt)}</b></div>
      <div className="actions">{children}{(o.status === 1 || o.status === 2) && <span className="mute small">Problem? Lodge a dispute in the Disputes tab.</span>}</div>
    </div>
  );
}
function useAct(m) {
  const w = useWallet();
  return (fn, ok) => w.run(async () => { await wait(fn()); await m.refresh(); }, ok);
}

export function IncomingOrders({ m }) {
  const w = useWallet(); const act = useAct(m);
  const list = m.orders.filter((o) => same(o.seller, w.account) && [1, 2, 6].includes(o.status)).reverse();
  if (!list.length) return <Empty>No open orders. When someone buys your item, it appears here.</Empty>;
  return <div className="grid">{list.map((o) => (
    <OrderCard key={o.id} o={o} m={m}>
      {o.status === 1 && <button className="btn" disabled={w.busy} onClick={() => act(() => w.c.escrowW.markDelivered(o.id), "Marked as delivered.")}>Mark delivered</button>}
      {o.status === 2 && <span className="mute small">Waiting for the buyer to confirm.</span>}
      {o.status === 6 && <span className="mute small">Disputed. See the Disputes tab.</span>}
    </OrderCard>))}</div>;
}

export function MyOrders({ m }) {
  const w = useWallet(); const act = useAct(m);
  const list = m.orders.filter((o) => same(o.buyer, w.account)).reverse();
  if (!list.length) return <Empty>You haven't bought anything yet. Browse the Market tab.</Empty>;
  return <div className="grid">{list.map((o) => (
    <OrderCard key={o.id} o={o} m={m}>
      {o.status === 2 && <button className="btn" disabled={w.busy} onClick={() => act(() => w.c.escrowW.confirmDelivery(o.id), "Delivery confirmed.")}>Confirm delivery</button>}
      {o.status === 1 && <button className="btn ghost" disabled={w.busy} onClick={() => act(() => w.c.escrowW.refundBeforeDelivery(o.id), "Refunded to your wallet.")}>Cancel and refund</button>}
    </OrderCard>))}</div>;
}

export function MySales({ m }) {
  const w = useWallet(); const act = useAct(m);
  const now = Math.floor(Date.now() / 1000);
  const list = m.orders.filter((o) => same(o.seller, w.account) && (o.status === 3 || o.status === 4 || (o.status === 2 && now >= o.deliveredAt + Number(m.window)))).reverse();
  const ready = list.filter((o) => o.status === 3).reduce((a, o) => a + o.amount, 0n);
  return (
    <div className="stack">
      <div className="block row"><span>Ready to redeem</span><b className="price">{fmt(ready)} TCH8</b></div>
      {!list.length && <Empty>Nothing to redeem yet. Orders show here after the buyer confirms delivery.</Empty>}
      <div className="grid">{list.map((o) => (
        <OrderCard key={o.id} o={o} m={m}>
          {o.status === 3 && <button className="btn" disabled={w.busy} onClick={() => act(() => w.c.escrowW.redeem(o.id), "TCH8 moved to your wallet.")}>Redeem token</button>}
          {o.status === 2 && <button className="btn" disabled={w.busy} onClick={() => act(() => w.c.escrowW.claimAfterWindow(o.id), "Order confirmed. You can redeem it now.")}>Confirm after waiting period</button>}
          {o.status === 4 && <span className="mute small">Redeemed on {when(o.confirmedAt)}</span>}
        </OrderCard>))}</div>
    </div>
  );
}

/* ---------------- Exchange ---------------- */
const CUR = ["USD", "NGN", "EUR", "GBP", "USDT", "BTC", "ETH", "Other"];
export function Exchange({ m }) {
  const w = useWallet();
  const [amt, setAmt] = useState(""); const [cur, setCur] = useState("USD"); const [det, setDet] = useState("");
  const mine = m.reds.filter((r) => same(r.seller, w.account)).reverse();
  const submit = () => w.run(async () => {
    if (!(Number(amt) > 0)) throw new Error("Enter an amount above 0.");
    if (!det.trim()) throw new Error("Add your payout details (bank account or wallet address).");
    const a = parseUnits(amt, 6);
    const bal = await w.c.token.balanceOf(w.account);
    if (bal < a) throw new Error(`You only hold ${fmt(bal)} TCH8.`);
    await ensureAllowance(w, a);
    w.notify("Step 2 of 2: confirm the exchange request…");
    await wait(w.c.escrowW.requestRedemption(a, cur, det.trim()));
    setAmt(""); setDet(""); await m.refresh();
  }, "Exchange requested. The operator will pay you in your chosen currency.");

  return (
    <div className="two">
      <div className="block form">
        <h3>Exchange TCH8 for currency</h3>
        <p className="mute">Balance: {fmt(m.balance)} TCH8. Your TCH8 is locked, then burned when the operator pays you.</p>
        <label>Amount (TCH8)<input inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value)} /></label>
        <label>Currency<select value={cur} onChange={(e) => setCur(e.target.value)}>{CUR.map((c) => <option key={c}>{c}</option>)}</select></label>
        <label>Payout details<textarea rows={3} value={det} onChange={(e) => setDet(e.target.value)} placeholder="Bank name, account number, or wallet address" maxLength={300} /></label>
        <button className="btn" disabled={w.busy} onClick={submit}>Request exchange</button>
      </div>
      <div className="stack">
        <h3 className="sec">Your requests</h3>
        {!mine.length && <Empty>No exchange requests yet.</Empty>}
        {mine.map((r) => (
          <div className="block" key={r.id}>
            <div className="row"><b>{fmt(r.amount)} TCH8 to {r.currency}</b><span className={`badge r${r.status}`}>{RSTATUS[r.status]}</span></div>
            <div className="mute small">{when(r.createdAt)}</div>
          </div>))}
      </div>
    </div>
  );
}

/* ---------------- Sales feed ---------------- */
export function soldOrders(m) { return m.orders.filter((o) => o.status === 3 || o.status === 4).sort((a, b) => b.confirmedAt - a.confirmedAt); }
export function SalesFeed({ m }) {
  const list = soldOrders(m);
  if (!list.length) return <Empty>No completed sales yet.</Empty>;
  return (
    <div className="block tablewrap">
      <table>
        <thead><tr><th>Item</th><th>Seller</th><th>Buyer</th><th>Amount</th><th>Time</th></tr></thead>
        <tbody>{list.map((o) => { const it = m.items.find((i) => i.id === o.itemId); return (
          <tr key={o.id}><td>{it ? it.title : `Item ${o.itemId}`}</td><td>{short(o.seller)}</td><td>{short(o.buyer)}</td><td>{fmt(o.amount)} TCH8</td><td>{when(o.confirmedAt)}</td></tr>); })}</tbody>
      </table>
    </div>
  );
}

/* ---------------- Admin ---------------- */
export function Admin({ m }) {
  const w = useWallet(); const act = useAct(m);
  const { saleGov, escGov, op } = m.roles;
  const isSale = same(w.account, saleGov), isEsc = same(w.account, escGov), isOp = same(w.account, op);
  const [price, setPrice] = useState(""); const [bal, setBal] = useState(0n);
  const [to, setTo] = useState(""); const [wd, setWd] = useState("");
  useEffect(() => { reader.getBalance(ADDR.sale).then(setBal).catch(() => {}); }, [m.price, m.orders.length]);
  const pending = m.reds.filter((r) => r.status === 1).reverse();
  const tickets = m.tickets.slice().sort((a, b) => (a.repliedAt > 0) - (b.repliedAt > 0) || b.createdAt - a.createdAt);

  return (
    <div className="stack">
      <div className="two">
        <div className="block form">
          <h3>TCH8 price</h3>
          <p className="mute">Current: 1 ETH = {(1 / Number(formatEther(m.price))).toLocaleString(undefined, { maximumFractionDigits: 8 })} TCH8</p>
          <label>New price (ETH per 1 TCH8)<input inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} placeholder="0.0001" /></label>
          <button className="btn" disabled={w.busy || !isSale} onClick={() => act(() => w.c.saleW.setPrice(parseEther(price)), "Price updated.")}>Update price</button>
        </div>
        <div className="block form">
          <h3>ETH collected</h3>
          <p className="price">{formatEther(bal)} ETH</p>
          <label>Send to<input value={to} onChange={(e) => setTo(e.target.value)} placeholder="0x…" /></label>
          <label>Amount (ETH)<input inputMode="decimal" value={wd} onChange={(e) => setWd(e.target.value)} /></label>
          <button className="btn" disabled={w.busy || !isSale} onClick={() => act(() => w.c.saleW.withdraw(getAddress(to), parseEther(wd)), "ETH withdrawn.")}>Withdraw ETH</button>
        </div>
      </div>
      <h3 className="sec">Exchange requests {isOp ? "" : "(operator wallet only)"}</h3>
      {!pending.length && <Empty>No pending exchange requests.</Empty>}
      <div className="grid">{pending.map((r) => (
        <div className="block order" key={r.id}>
          <b>{fmt(r.amount)} TCH8 to {r.currency}</b>
          <div className="kv"><span>Seller</span><b>{short(r.seller)}</b></div>
          <div className="kv"><span>Payout</span><b className="wrap">{r.details}</b></div>
          <div className="actions">
            <button className="btn" disabled={w.busy || !isOp} onClick={() => act(() => w.c.escrowW.confirmRedemption(r.id), "Marked as paid and TCH8 burned.")}>I paid this</button>
            <button className="btn ghost" disabled={w.busy || !isOp} onClick={() => act(() => w.c.escrowW.rejectRedemption(r.id), "Rejected and TCH8 returned.")}>Reject</button>
          </div>
        </div>))}</div>
      <h3 className="sec">Complaints and enquiries {isEsc ? "" : "(admin wallet only)"}</h3>
      {!tickets.length && <Empty>No messages from members yet.</Empty>}
      <div className="grid">{tickets.map((t) => (
        <TicketCard key={t.id} t={t}>
          {isEsc && <ReplyBox label={t.repliedAt ? "Update reply" : "Send reply"} disabled={w.busy} onSend={(text) => act(() => w.c.escrowW.replyTicket(t.id, text), "Reply sent.")} />}
        </TicketCard>))}</div>
    </div>
  );
}

/* ---------------- shared bits for complaints and disputes ---------------- */
const KIND = ["Complaint", "Enquiry"];

function ReplyBox({ label, disabled, onSend }) {
  const [text, setText] = useState("");
  return (
    <div className="stack">
      <textarea rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="Type your reply…" maxLength={1000} />
      <button className="btn" disabled={disabled || !text.trim()} onClick={async () => { if (await onSend(text.trim())) setText(""); }}>{label}</button>
    </div>
  );
}

function TicketCard({ t, children }) {
  return (
    <div className="block order">
      <div className="row"><b className="wrap">{t.subject}</b><span className={`badge ${t.repliedAt ? "s3" : "s1"}`}>{t.repliedAt ? "Answered" : "Waiting for reply"}</span></div>
      <div className="mute small">{KIND[t.kind]} from {short(t.author)} · {when(t.createdAt)}</div>
      <p className="msg">{t.message}</p>
      {t.repliedAt > 0 && <div className="reply"><b>Admin reply</b> <span className="mute small">{when(t.repliedAt)}</span><p>{t.reply}</p></div>}
      {children}
    </div>
  );
}

/* ---------------- Complaints / enquiries (members) ---------------- */
export function Complaints({ m }) {
  const w = useWallet();
  const [kind, setKind] = useState("0"); const [subject, setSubject] = useState(""); const [message, setMessage] = useState("");
  const mine = m.tickets.filter((t) => same(t.author, w.account)).reverse();
  const send = () => w.run(async () => {
    if (!subject.trim() || !message.trim()) throw new Error("Add a subject and a message.");
    await wait(w.c.escrowW.submitTicket(Number(kind), subject.trim(), message.trim()));
    setSubject(""); setMessage(""); await m.refresh();
  }, "Sent. The admin will reply here.");
  return (
    <div className="two">
      <div className="block form">
        <h3>Send a complaint or enquiry</h3>
        <p className="mute">The admin reads every message and replies on this page. For a problem with a specific order, use the Disputes tab.</p>
        <label>Type<select value={kind} onChange={(e) => setKind(e.target.value)}><option value="0">Complaint</option><option value="1">Enquiry</option></select></label>
        <label>Subject<input value={subject} onChange={(e) => setSubject(e.target.value)} maxLength={120} /></label>
        <label>Message<textarea rows={5} value={message} onChange={(e) => setMessage(e.target.value)} maxLength={1000} /></label>
        <button className="btn" disabled={w.busy} onClick={send}>Send message</button>
      </div>
      <div className="stack">
        <h3 className="sec">Your messages</h3>
        {!mine.length && <Empty>You haven't sent any messages yet.</Empty>}
        {mine.map((t) => <TicketCard key={t.id} t={t} />)}
      </div>
    </div>
  );
}

/* ---------------- Disputes (members lodge, governance resolves) ---------------- */
function ResolveBox({ id, m }) {
  const w = useWallet(); const act = useAct(m);
  const [text, setText] = useState("");
  const go = (toSeller) => {
    if (!text.trim()) return w.notify("Write a reply explaining your decision first.", "err");
    return act(() => w.c.escrowW.resolveDispute(id, toSeller, text.trim()), toSeller ? "Resolved: seller paid." : "Resolved: buyer refunded.");
  };
  return (
    <div className="stack">
      <textarea rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="Your decision and reply to both parties…" maxLength={1000} />
      <div className="actions">
        <button className="btn" disabled={w.busy} onClick={() => go(true)}>Pay seller</button>
        <button className="btn ghost" disabled={w.busy} onClick={() => go(false)}>Refund buyer</button>
      </div>
    </div>
  );
}

export function Disputes({ m }) {
  const w = useWallet();
  const isGov = same(w.account, m.roles.escGov);
  const eligible = m.orders.filter((o) => (same(o.buyer, w.account) || same(o.seller, w.account)) && (o.status === 1 || o.status === 2)).reverse();
  const [orderId, setOrderId] = useState(""); const [reason, setReason] = useState("");
  const titleOf = (o) => { const it = o && m.items.find((i) => i.id === o.itemId); return it ? it.title : o ? `Item ${o.itemId}` : "Order"; };

  const submit = () => w.run(async () => {
    if (orderId === "") throw new Error("Choose the order you have a problem with.");
    if (!reason.trim()) throw new Error("Describe the problem.");
    await wait(w.c.escrowW.raiseDispute(BigInt(orderId), reason.trim()));
    setReason(""); setOrderId(""); await m.refresh();
  }, "Dispute lodged. The funds stay frozen until the admin decides.");

  const list = m.disputes.filter((d) => {
    if (isGov || same(d.raisedBy, w.account)) return true;
    const o = m.orders.find((x) => x.id === d.orderId);
    return o && (same(o.buyer, w.account) || same(o.seller, w.account));
  }).sort((a, b) => (a.resolvedAt > 0) - (b.resolvedAt > 0) || b.raisedAt - a.raisedAt);

  return (
    <div className="two">
      <div className="block form">
        <h3>Lodge a dispute</h3>
        <p className="mute">Use this if the other side is not cooperating on an order. The TCH8 stays locked in escrow until the admin decides.</p>
        <label>Order<select value={orderId} onChange={(e) => setOrderId(e.target.value)}>
          <option value="">Choose an order…</option>
          {eligible.map((o) => <option key={o.id} value={o.id}>#{o.id} {titleOf(o)} · {fmt(o.amount)} TCH8 · {same(o.buyer, w.account) ? "you are the buyer" : "you are the seller"}</option>)}
        </select></label>
        {!eligible.length && <p className="mute small">No open orders to dispute. Only orders that are paid or delivered, and not yet confirmed, can be disputed.</p>}
        <label>What went wrong?<textarea rows={5} value={reason} onChange={(e) => setReason(e.target.value)} maxLength={1000} /></label>
        <button className="btn" disabled={w.busy} onClick={submit}>Lodge dispute</button>
      </div>
      <div className="stack">
        <h3 className="sec">{isGov ? "All disputes" : "Your disputes"}</h3>
        {!list.length && <Empty>No disputes.</Empty>}
        {list.map((d) => {
          const o = m.orders.find((x) => x.id === d.orderId);
          const done = d.resolvedAt > 0;
          return (
            <div className="block order" key={d.orderId}>
              <div className="row"><b>Order #{d.orderId} {titleOf(o)}</b><span className={`badge ${done ? (d.releasedToSeller ? "s3" : "s5") : "s6"}`}>{done ? (d.releasedToSeller ? "Resolved: seller paid" : "Resolved: buyer refunded") : "Open"}</span></div>
              {o && <div className="kv"><span>Amount</span><b>{fmt(o.amount)} TCH8</b></div>}
              {o && <div className="kv"><span>Buyer / Seller</span><b>{short(o.buyer)} / {short(o.seller)}</b></div>}
              <div className="mute small">Lodged by {short(d.raisedBy)} · {when(d.raisedAt)}</div>
              <p className="msg">{d.reason}</p>
              {done && <div className="reply"><b>Admin decision</b> <span className="mute small">{when(d.resolvedAt)}</span><p>{d.reply}</p></div>}
              {!done && isGov && <ResolveBox id={d.orderId} m={m} />}
              {!done && !isGov && <span className="mute small">Waiting for the admin to review.</span>}
            </div>);
        })}
      </div>
    </div>
  );
}
