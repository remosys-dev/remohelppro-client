/**
 * Stripe からのお知らせを受ける口（公開・POST）。
 *
 * 🔴 **署名を必ず確かめる。** ここは誰でも叩ける場所なので、
 *   確かめないと「支払われました」という嘘の通知で請求書を消せてしまう。
 *   署名鍵（STRIPE_WEBHOOK_SECRET）が無いときは、何も受け付けない。
 *
 * 🔴 本文は**生のまま**読むこと。JSON に直すと署名が合わなくなる。
 *
 * ⚠ 同じお知らせが何度も来ることがある（Stripe の仕様）。
 *   何度受け取っても同じ結果になるようにしてある（条件付き更新）。
 */

import { NextResponse, type NextRequest } from 'next/server';
import { and, eq, or } from 'drizzle-orm';
import Stripe from 'stripe';
import { db } from '@/db/client';
import { billingInvoices } from '@/db/schema';
import { getStripe } from '@/lib/stripe';

export const dynamic = 'force-dynamic';

export async function POST(req: NextRequest) {
  const stripe = getStripe();
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  // 鍵が無いときは受け付けない。「たぶん本物だろう」で通さない。
  if (!stripe || !secret) {
    return NextResponse.json({ ok: false }, { status: 503 });
  }

  const sig = req.headers.get('stripe-signature');
  if (!sig) return NextResponse.json({ ok: false }, { status: 400 });

  let event: Stripe.Event;
  try {
    const raw = await req.text(); // 🔴 生のまま
    event = stripe.webhooks.constructEvent(raw, sig, secret);
  } catch {
    // 署名が合わない＝Stripe からではない。理由は返さない。
    return NextResponse.json({ ok: false }, { status: 400 });
  }

  try {
    if (event.type === 'payment_intent.succeeded') {
      const pi = event.data.object as Stripe.PaymentIntent;
      const invoiceId = pi.metadata?.invoiceId;
      if (invoiceId) {
        // ⚠ 未払いのものだけを支払い済みにする（二重に書き換えない）。
        await db
          .update(billingInvoices)
          .set({
            status: 'paid',
            paidAt: new Date(),
            paidAmount: pi.amount_received || pi.amount,
            matchedBy: 'card_auto',
            stripePaymentIntentId: pi.id,
            cardFailureMessage: null,
            updatedAt: new Date(),
          })
          .where(
            and(
              eq(billingInvoices.id, invoiceId),
              or(
                eq(billingInvoices.status, 'unpaid'),
                eq(billingInvoices.status, 'partial')
              )
            )
          );
      }
    } else if (event.type === 'payment_intent.payment_failed') {
      const pi = event.data.object as Stripe.PaymentIntent;
      const invoiceId = pi.metadata?.invoiceId;
      if (invoiceId) {
        // 請求書は消さない。未払いのまま残し、理由だけ記録する。
        await db
          .update(billingInvoices)
          .set({
            cardFailureMessage: (
              pi.last_payment_error?.message ?? 'カードでのお支払いができませんでした。'
            ).slice(0, 500),
            cardAttemptedAt: new Date(),
            updatedAt: new Date(),
          })
          .where(eq(billingInvoices.id, invoiceId));
      }
    }
  } catch {
    // ここで失敗しても Stripe には成功を返す。
    //   失敗を返すと Stripe が何度も送り直してくる。
    //   取りこぼしは、こちらの引き落とし処理が結果を持っているので追える。
  }

  return NextResponse.json({ received: true });
}
