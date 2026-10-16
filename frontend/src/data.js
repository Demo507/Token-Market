import { useCallback, useEffect, useState } from "react";
import { useWallet } from "./wallet";
import { ADDR } from "./config";

const LIMIT = 100;
const range = (from, to) => Array.from({ length: Math.max(0, to - from) }, (_, i) => from + i);
const tail = (n, k = LIMIT) => range(Math.max(0, Number(n) - k), Number(n));

export function useMarket() {
  const { c, account } = useWallet();
  const [d, setD] = useState({ items: [], orders: [], disputes: [], tickets: [], reds: [], purchases: [], balance: 0n, supply: 0n, maxSupply: 0n, locked: 0n, price: 1n, window: 0n, roles: {}, loading: true, error: "" });

  const refresh = useCallback(async () => {
    if (!account) return;
    try {
      const [balance, price, win, nI, nO, nR, nP, saleGov, escGov, op, supply, maxSupply, locked, nD, nT] = await Promise.all([
        c.token.balanceOf(account), c.sale.priceWeiPerToken(), c.escrow.autoReleaseWindow(),
        c.escrow.itemCount(), c.escrow.orderCount(), c.escrow.redemptionCount(), c.sale.purchaseCount(),
        c.sale.governance(), c.escrow.governance(), c.escrow.operator(),
        c.token.totalSupply(), c.token.maxSupply(), c.token.balanceOf(ADDR.escrow),
        c.escrow.disputeCount(), c.escrow.ticketCount(),
      ]);
      const [items, orders, reds, purchases, disputes, tickets] = await Promise.all([
        Promise.all(tail(nI).map(async (i) => { const r = await c.escrow.items(i);
          return { id: i, seller: r.seller, price: r.price, quantity: Number(r.quantity), active: r.active, createdAt: Number(r.createdAt),title: r.title, description: r.description }; })),
        Promise.all(tail(nO).map(async (i) => { const r = await c.escrow.orders(i);
          return { id: i, itemId: Number(r.itemId), buyer: r.buyer, seller: r.seller, amount: r.amount, createdAt: Number(r.createdAt), deliveredAt: Number(r.deliveredAt), confirmedAt: Number(r.confirmedAt), status: Number(r.status) }; })),
        Promise.all(tail(nR).map(async (i) => { const r = await c.escrow.redemptions(i);
          return { id: i, seller: r.seller, amount: r.amount, createdAt: Number(r.createdAt), status: Number(r.status), currency: r.currency, details: r.details }; })),
        Promise.all(tail(nP, 20).map(async (i) => { const r = await c.sale.purchases(i);
          return { buyer: r.buyer, ethPaid: r.ethPaid, tokensOut: r.tokensOut, time: Number(r.time) }; })),
        Promise.all(tail(nD).map(async (i) => { const orderId = Number(await c.escrow.disputedOrderIds(i)); const r = await c.escrow.disputes(orderId);
          return { orderId, raisedBy: r.raisedBy, raisedAt: Number(r.raisedAt), resolvedAt: Number(r.resolvedAt), releasedToSeller: r.releasedToSeller, reason: r.reason, reply: r.reply }; })),
        Promise.all(tail(nT).map(async (i) => { const r = await c.escrow.tickets(i);
          return { id: i, author: r.author, kind: Number(r.kind), createdAt: Number(r.createdAt), repliedAt: Number(r.repliedAt), subject: r.subject, message: r.message, reply: r.reply }; })),
      ]);
      setD({ items, orders, reds, purchases, disputes, tickets, balance, supply, maxSupply, locked, price, window: win, roles: { saleGov, escGov, op }, loading: false, error: "" });
    } catch (e) {
      console.error(e);
      setD((x) => ({ ...x, loading: false, error: "Could not read the contracts. Check the addresses in deployed.json / env vars and that they are on Sepolia." }));
    }
  }, [c, account]);

  useEffect(() => { refresh(); const t = setInterval(refresh, 15000); return () => clearInterval(t); }, [refresh]);
  return { ...d, refresh };
}
