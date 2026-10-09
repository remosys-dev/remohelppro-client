// RemoSys自作エンジン I-1.5: QUIC 映像DATAGRAM の受け皿 QuicFramedStream
//
// 設計: docs/engine_integration_i1_5_video_datagram.md（RemoSys リポジトリ）。
// - 制御/ファイル = 信頼 bi-stream(FramedStream)。従来どおり secretbox 暗号＋順序保証。
// - 映像(VideoFrame) = **不確実 QUIC DATAGRAM**。分割→送出／背景タスクで再結合→next() で合流。
//   1パケット欠けはそのコマを捨てて次へ（HoL ブロッキング解消＝本命価値）。
//   ⚠ 映像は QUIC の TLS で暗号化される（secretbox は掛けない＝二重暗号回避・§6-E）。
//
// engine-poc m2_pipeline の分割/再結合をそのまま移植（[[verified-not-assumed]]）。

use crate::{tcp::FramedStream, ResultType};
use bytes::{BufMut, Bytes, BytesMut};
use sodiumoxide::crypto::secretbox::Key;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

// DATAGRAM ワイヤ形式:
//   映像: [T_VIDEO:u8][frame:u32][frag_idx:u16][frag_cnt:u16][total:u32][payload...]
//   ACK : [T_ACK:u8][frame:u32]  (受信側→送信側。in-flight=1 のため)
const T_VIDEO: u8 = 0;
const T_ACK: u8 = 1;
const VHDR: usize = 1 + 4 + 2 + 2 + 4; // 13
const VIDEO_CH: usize = 64; // 再結合済みフレームのチャネル長
// in-flight=1: 前フレームのACKがこの時間内に来なければ、ロストと見なし次を送る（死活回避）
const ACK_TIMEOUT: Duration = Duration::from_millis(200);
// I-1.5-d 方式①: コマ落ちを検知してもキーフレーム要求はこの間隔までに抑える（refresh 氾濫防止）。
const LOSS_SIGNAL_INTERVAL: Duration = Duration::from_millis(500);

pub struct QuicFramedStream {
    /// 信頼 bi-stream＝制御・ファイル
    control: FramedStream,
    /// 映像 DATAGRAM 送出用
    conn: quinn::Connection,
    /// 背景タスクが再結合した映像フレーム（＝Messageの直列化バイト列）を受ける
    video_rx: mpsc::Receiver<BytesMut>,
    video_closed: bool,
    /// 送出フレーム通し番号
    send_seq: u32,
    /// in-flight=1: 送信中(ACK未達)か。背景タスク(ACK受信)が false にする。
    waiting_ack: Arc<AtomicBool>,
    /// 直近の映像送出時刻（ACKタイムアウト判定用）
    last_video_sent: Option<Instant>,
    /// I-1.5-d 方式①: 受信側でコマ落ち(未完成フレーム破棄)を検知したら true。
    ///   上位(io_loop)が took_video_loss() で拾い、デコード前に先行キーフレーム要求を出す。
    video_loss: Arc<AtomicBool>,
}

impl QuicFramedStream {
    pub fn new(control: FramedStream, conn: quinn::Connection) -> Self {
        // 背景タスク: DATAGRAM を読み、映像は再結合してチャネルへ／ACK は waiting_ack を下ろす。
        let (tx, rx) = mpsc::channel::<BytesMut>(VIDEO_CH);
        let waiting_ack = Arc::new(AtomicBool::new(false));
        let video_loss = Arc::new(AtomicBool::new(false));
        let c = conn.clone();
        let w = waiting_ack.clone();
        let l = video_loss.clone();
        tokio::spawn(async move {
            reassembly_loop(c, tx, w, l).await;
        });
        Self {
            control,
            conn,
            video_rx: rx,
            video_closed: false,
            send_seq: 0,
            waiting_ack,
            last_video_sent: None,
            video_loss,
        }
    }

    /// I-1.5-d 方式①: 受信側でコマ落ちを検知していたら true を返してフラグを下ろす（消費）。
    ///   上位はこれが true のとき `refresh_video`（キーフレーム要求）を出す＝崩れた絵を見せず早く復帰。
    #[inline]
    pub fn took_video_loss(&self) -> bool {
        self.video_loss.swap(false, Ordering::AcqRel)
    }

    /// 映像フレーム(Message)を DATAGRAM で送る。分割して送出（欠けは受信側でコマ落ち）。
    /// ★in-flight=1：前フレームの ACK 未達（かつタイムアウト前）なら、今のコマは送らず捨てる
    ///   ＝未確認フレームを常に1枚に抑え、細い/揺れる回線で遅延を積まない（M2 で実証）。
    pub async fn send_video(&mut self, msg: &impl protobuf::Message) -> ResultType<()> {
        // 前フレームが送信中(ACK未達)で、まだタイムアウトしていなければ、このコマは捨てる。
        if self.waiting_ack.load(Ordering::Acquire) {
            let fresh = self
                .last_video_sent
                .map(|t| t.elapsed() < ACK_TIMEOUT)
                .unwrap_or(false);
            if fresh {
                return Ok(()); // 最新優先で古いコマは捨てる
            }
            // タイムアウト＝ACK が来ない（ロスト等）→ 送って良い（死活回避）
        }

        let data = msg.write_to_bytes()?;
        let total = data.len();
        let max_dg = self.conn.max_datagram_size().unwrap_or(1200).min(1200);
        let payload = max_dg.saturating_sub(VHDR).max(1);
        let frag_cnt = ((total + payload - 1) / payload).max(1) as u16;
        let frame = self.send_seq;
        self.send_seq = self.send_seq.wrapping_add(1);
        for idx in 0..frag_cnt {
            let s = idx as usize * payload;
            let e = (s + payload).min(total);
            let mut buf = BytesMut::with_capacity(VHDR + (e - s));
            buf.put_u8(T_VIDEO);
            buf.put_u32_le(frame);
            buf.put_u16_le(idx);
            buf.put_u16_le(frag_cnt);
            buf.put_u32_le(total as u32);
            buf.put_slice(&data[s..e]);
            let _ = self.conn.send_datagram(buf.freeze());
        }
        self.waiting_ack.store(true, Ordering::Release);
        self.last_video_sent = Some(Instant::now());
        Ok(())
    }

    #[inline]
    pub fn set_send_timeout(&mut self, ms: u64) {
        self.control.set_send_timeout(ms)
    }
    #[inline]
    pub fn set_raw(&mut self) {
        self.control.set_raw()
    }
    #[inline]
    pub async fn send_bytes(&mut self, bytes: Bytes) -> ResultType<()> {
        self.control.send_bytes(bytes).await
    }
    #[inline]
    pub async fn send_raw(&mut self, bytes: Vec<u8>) -> ResultType<()> {
        self.control.send_raw(bytes).await
    }
    #[inline]
    pub fn set_key(&mut self, key: Key) {
        self.control.set_key(key)
    }
    #[inline]
    pub fn is_secured(&self) -> bool {
        self.control.is_secured()
    }
    #[inline]
    pub async fn send(&mut self, msg: &impl protobuf::Message) -> ResultType<()> {
        self.control.send(msg).await
    }

    /// 制御(信頼)と映像(DATAGRAM再結合)を合流して次のメッセージを返す。
    pub async fn next(&mut self) -> Option<Result<BytesMut, std::io::Error>> {
        loop {
            tokio::select! {
                ctrl = self.control.next() => return ctrl,
                v = self.video_rx.recv(), if !self.video_closed => {
                    match v {
                        Some(bytes) => return Some(Ok(bytes)),
                        None => { self.video_closed = true; } // 映像ch閉鎖→以後は制御のみ
                    }
                }
            }
        }
    }

    pub async fn next_timeout(
        &mut self,
        timeout: u64,
    ) -> Option<Result<BytesMut, std::io::Error>> {
        match tokio::time::timeout(std::time::Duration::from_millis(timeout), self.next()).await {
            Ok(x) => x,
            Err(_) => None,
        }
    }

    #[inline]
    pub fn local_addr(&self) -> SocketAddr {
        self.control.local_addr()
    }
}

/// 背景: DATAGRAM を読み、映像(T_VIDEO)は再結合して tx へ＋ACKを返す／ACK(T_ACK)は waiting_ack を下ろす。
async fn reassembly_loop(
    conn: quinn::Connection,
    tx: mpsc::Sender<BytesMut>,
    waiting_ack: Arc<AtomicBool>,
    video_loss: Arc<AtomicBool>,
) {
    struct Asm {
        cnt: u16,
        total: u32,
        got: u16,
        parts: Vec<Option<Bytes>>,
    }
    let mut asm: HashMap<u32, Asm> = HashMap::new();
    let mut max_seen: u32 = 0;
    // 直近にロス合図を出した時刻（最初のロスは即出せるよう過去に寄せる）。
    let mut last_loss_signal = Instant::now()
        .checked_sub(LOSS_SIGNAL_INTERVAL)
        .unwrap_or_else(Instant::now);
    loop {
        let dg = match conn.read_datagram().await {
            Ok(d) => d,
            Err(_) => break, // 接続終了
        };
        if dg.is_empty() {
            continue;
        }
        // ACK（受信側→送信側）：in-flight=1 の待ちを解除
        if dg[0] == T_ACK {
            waiting_ack.store(false, Ordering::Release);
            continue;
        }
        if dg[0] != T_VIDEO || dg.len() < VHDR {
            continue;
        }
        let frame = u32::from_le_bytes([dg[1], dg[2], dg[3], dg[4]]);
        let idx = u16::from_le_bytes([dg[5], dg[6]]);
        let cnt = u16::from_le_bytes([dg[7], dg[8]]);
        let total = u32::from_le_bytes([dg[9], dg[10], dg[11], dg[12]]);
        if cnt == 0 {
            continue;
        }
        if frame.wrapping_sub(max_seen) < 0x8000_0000 {
            max_seen = frame;
        }
        let ent = asm.entry(frame).or_insert_with(|| Asm {
            cnt,
            total,
            got: 0,
            parts: vec![None; cnt as usize],
        });
        if (idx as usize) < ent.parts.len() && ent.parts[idx as usize].is_none() {
            ent.parts[idx as usize] = Some(dg.slice(VHDR..));
            ent.got += 1;
        }
        if ent.got == ent.cnt {
            let mut out = BytesMut::with_capacity(ent.total as usize);
            for p in &ent.parts {
                if let Some(b) = p {
                    out.put_slice(b);
                }
            }
            asm.remove(&frame);
            // ★ACK を即返す（送信側の in-flight=1 を回す）
            let mut ack = BytesMut::with_capacity(5);
            ack.put_u8(T_ACK);
            ack.put_u32_le(frame);
            let _ = conn.send_datagram(ack.freeze());
            if tx.send(out).await.is_err() {
                break; // 受け手が消えた
            }
            // 古い未完成フレームを掃除（＝欠けたコマを捨てる）。
            // ★I-1.5-d 方式①: 掃除で「未完成のまま」捨てるフレームがあれば＝確定コマ落ち。
            //   LOSS_SIGNAL_INTERVAL で間引いて video_loss を立て、上位に先行 refresh を促す。
            let cutoff = max_seen.wrapping_sub(8);
            let dropped_incomplete = asm
                .iter()
                .any(|(&k, a)| k.wrapping_sub(cutoff) >= 0x8000_0000 && a.got < a.cnt);
            asm.retain(|&k, _| k.wrapping_sub(cutoff) < 0x8000_0000);
            if dropped_incomplete && last_loss_signal.elapsed() > LOSS_SIGNAL_INTERVAL {
                video_loss.store(true, Ordering::Release);
                last_loss_signal = Instant::now();
            }
        }
    }
}
