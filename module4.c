#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "module4.h"
#include "module2.h"
#include "module3.h"
#include "module1.h"
#include "TCP/mbuf.h"
#include "TCP/sockvar.h"
#include "na_conf.h"
#include "na_log.h"

int tcp_usr_send(struct socket *so, struct mbuf *m);

static struct module4_state g_m4;

/* ============ per-peer table: generation + cold + confirmed bitmap == */
struct peer_gen_entry {
    uint32_t peer_key;
    uint32_t generation;
    uint8_t  is_cold;
    uint8_t  in_use;
    uint32_t nak_burst;
    uint8_t  confirmed[MODULE4_BITMAP_BYTES];   /* V2: 1 bit per sender cid */
};
static struct peer_gen_entry g_peers[MODULE4_MAX_PEERS];

static struct peer_gen_entry *peer_find(uint32_t key)
{
    int i;
    for (i = 0; i < MODULE4_MAX_PEERS; i++)
        if (g_peers[i].in_use && g_peers[i].peer_key == key)
            return &g_peers[i];
    return NULL;
}

static struct peer_gen_entry *peer_find_or_add(uint32_t key)
{
    int i;
    struct peer_gen_entry *e = peer_find(key);
    if (e) return e;
    for (i = 0; i < MODULE4_MAX_PEERS; i++) {
        if (!g_peers[i].in_use) {
            memset(&g_peers[i], 0, sizeof(g_peers[i]));
            g_peers[i].in_use   = 1;
            g_peers[i].peer_key = key;
            g_peers[i].is_cold  = 1;      /* unknown peer = cold (safe) */
            return &g_peers[i];
        }
    }
    return NULL;
}

static uint32_t peer_key_of(struct socket *so)
{
    if (so == NULL || so->tp == NULL || so->tp->t_tcblut == NULL) return 0;
    return so->tp->t_tcblut->gre_dstIP;
}

static inline int bit_test(struct peer_gen_entry *e, uint32_t cid)
{
    if (cid == 0 || cid > MODULE4_CID_SPACE) return 0;
    cid--;
    return (e->confirmed[cid >> 3] >> (cid & 7)) & 1;
}
static inline void bit_set(struct peer_gen_entry *e, uint32_t cid)
{
    if (cid == 0 || cid > MODULE4_CID_SPACE) return;
    cid--;
    e->confirmed[cid >> 3] |= (uint8_t)(1U << (cid & 7));
}
static inline void bit_clear(struct peer_gen_entry *e, uint32_t cid)
{
    if (cid == 0 || cid > MODULE4_CID_SPACE) return;
    cid--;
    e->confirmed[cid >> 3] &= (uint8_t)~(1U << (cid & 7));
}

/* ==================== TLV builders ================================ */
static struct mbuf *build_tlv_mbuf(uint8_t type, uint8_t *val, uint16_t val_len)
{
    uint32_t     total = (uint32_t)TLV_HDR_SIZE + val_len;
    uint32_t     done = 0, left = val_len;
    struct mbuf *head = NULL, *tail = NULL, *m;
    uint8_t     *buf;
    uint32_t     space, n;
    int          first = 1;

    while (first || left > 0) {
        if (first) {
            MGETHDR(m, 0, MT_DATA);
            if (!m) { if (head) m_freem(head); return NULL; }
            m->m_hdr.mh_next = NULL; m->m_hdr.mh_nextpkt = NULL;
            m->M_dat.MH.MH_pkthdr.len = 0; m->M_dat.MH.MH_pkthdr.rcvif = 1;
        } else {
            MGET(m, 0, MT_DATA);
            if (!m) { if (head) m_freem(head); return NULL; }
            m->m_hdr.mh_next = NULL; m->m_hdr.mh_nextpkt = NULL;
            m->m_flags &= ~M_PKTHDR;
        }
        if (total > MHLEN || (!first && left > MLEN)) {
            MCLGET(m, 0, 1);
            if (!(m->m_flags & M_EXT)) { m_free(m); if (head) m_freem(head); return NULL; }
        }
        buf = mtod(m, uint8_t *);
        if (first) {
            buf[0] = type;
            buf[1] = (val_len >> 8) & 0xFF;
            buf[2] = (val_len >> 0) & 0xFF;
            space  = (m->m_flags & M_EXT) ? m->m_ext.ext_size : (uint32_t)MHLEN;
            space -= TLV_HDR_SIZE;
            n = (left < space) ? left : space;
            memcpy(buf + TLV_HDR_SIZE, val + done, n);
            m->m_len = TLV_HDR_SIZE + n;
            done += n; left -= n;
            head = m; tail = m; first = 0;
        } else {
            space = (m->m_flags & M_EXT) ? m->m_ext.ext_size : (uint32_t)MLEN;
            n = (left < space) ? left : space;
            memcpy(buf, val + done, n);
            m->m_len = n;
            done += n; left -= n;
            tail->m_next = m; tail = m;
        }
    }
    head->m_pkthdr.len = (int)total;
    return head;
}

/* value = prefix + val, for MISS's [cid][data]. */
static void copy_logical(uint8_t *dst, const uint8_t *pfx, uint16_t plen,
                          const uint8_t *val, uint32_t vlen,
                          uint32_t off, uint32_t n)
{
    uint32_t copied = 0;
    (void)vlen;
    if (off < plen) {
        uint32_t take = plen - off; if (take > n) take = n;
        memcpy(dst, pfx + off, take);
        copied += take; off += take;
    }
    if (copied < n)
        memcpy(dst + copied, val + (off - plen), n - copied);
}

static struct mbuf *build_tlv_mbuf_pfx(uint8_t type,
                                       const uint8_t *pfx, uint16_t plen,
                                       const uint8_t *val, uint32_t vlen)
{
    uint32_t     vtot = (uint32_t)plen + vlen;
    uint32_t     total = (uint32_t)TLV_HDR_SIZE + vtot;
    uint32_t     done = 0, left = vtot;
    struct mbuf *head = NULL, *tail = NULL, *m;
    uint8_t     *buf;
    uint32_t     space, n;
    int          first = 1;

    while (first || left > 0) {
        if (first) {
            MGETHDR(m, 0, MT_DATA);
            if (!m) { if (head) m_freem(head); return NULL; }
            m->m_hdr.mh_next = NULL; m->m_hdr.mh_nextpkt = NULL;
            m->M_dat.MH.MH_pkthdr.len = 0; m->M_dat.MH.MH_pkthdr.rcvif = 1;
        } else {
            MGET(m, 0, MT_DATA);
            if (!m) { if (head) m_freem(head); return NULL; }
            m->m_hdr.mh_next = NULL; m->m_hdr.mh_nextpkt = NULL;
            m->m_flags &= ~M_PKTHDR;
        }
        if (total > MHLEN || (!first && left > MLEN)) {
            MCLGET(m, 0, 1);
            if (!(m->m_flags & M_EXT)) { m_free(m); if (head) m_freem(head); return NULL; }
        }
        buf = mtod(m, uint8_t *);
        if (first) {
            buf[0] = type;
            buf[1] = (vtot >> 8) & 0xFF;
            buf[2] = (vtot >> 0) & 0xFF;
            space  = (m->m_flags & M_EXT) ? m->m_ext.ext_size : (uint32_t)MHLEN;
            space -= TLV_HDR_SIZE;
            n = (left < space) ? left : space;
            copy_logical(buf + TLV_HDR_SIZE, pfx, plen, val, vlen, done, n);
            m->m_len = TLV_HDR_SIZE + n;
            done += n; left -= n;
            head = m; tail = m; first = 0;
        } else {
            space = (m->m_flags & M_EXT) ? m->m_ext.ext_size : (uint32_t)MLEN;
            n = (left < space) ? left : space;
            copy_logical(buf, pfx, plen, val, vlen, done, n);
            m->m_len = n;
            done += n; left -= n;
            tail->m_next = m; tail = m;
        }
    }
    head->m_pkthdr.len = (int)total;
    return head;
}

static struct mbuf *build_raw_mbuf(uint8_t *data, uint32_t len)
{
    uint32_t     done = 0, left = len;
    struct mbuf *head = NULL, *tail = NULL, *m;
    uint8_t     *buf;
    uint32_t     space, n;
    int          first = 1;

    if (!data || len == 0) return NULL;
    while (left > 0) {
        if (first) {
            MGETHDR(m, 0, MT_DATA);
            if (!m) { if (head) m_freem(head); return NULL; }
            m->m_hdr.mh_next = NULL; m->m_hdr.mh_nextpkt = NULL;
            m->M_dat.MH.MH_pkthdr.len = 0; m->M_dat.MH.MH_pkthdr.rcvif = 0;
        } else {
            MGET(m, 0, MT_DATA);
            if (!m) { if (head) m_freem(head); return NULL; }
            m->m_hdr.mh_next = NULL; m->m_hdr.mh_nextpkt = NULL;
            m->m_flags &= ~M_PKTHDR;
        }
        if (left > (uint32_t)(first ? MHLEN : MLEN)) {
            MCLGET(m, 0, 0);
            if (!(m->m_flags & M_EXT)) { m_free(m); if (head) m_freem(head); return NULL; }
        }
        buf   = mtod(m, uint8_t *);
        space = (m->m_flags & M_EXT) ? m->m_ext.ext_size : (uint32_t)(first ? MHLEN : MLEN);
        n = (left < space) ? left : space;
        memcpy(buf, data + done, n);
        m->m_len = n;
        done += n; left -= n;
        if (first) { head = m; tail = m; first = 0; }
        else       { tail->m_next = m; tail = m; }
    }
    head->m_pkthdr.len = (int)len;
    return head;
}

/* ============== V2: stall-at-gap reorder queue ===================== */
struct reorder_rec {
    struct reorder_rec *next;
    struct mbuf        *data;                     /* NULL while a hole */
    uint8_t             is_hole;
    uint8_t             hole_hash[MODULE4_HASH_SIZE];
};

static void ro_drain(struct module1_state *ms, struct socket *so2)
{
    while (ms->ro_head && !ms->ro_head->is_hole) {
        struct reorder_rec *r = ms->ro_head;
        ms->ro_head = r->next;
        if (ms->ro_head == NULL) ms->ro_tail = NULL;
        ms->ro_count--;
        if (r->data) tcp_usr_send(so2, r->data);
        free(r);
    }
}

static void ro_enqueue(struct module1_state *ms, struct mbuf *data,
                        int is_hole, const uint8_t *hash)
{
    struct reorder_rec *r = malloc(sizeof(*r));
    if (!r) {                        /* allocation failure (~never for
                                        48B): drop the record, loudly.
                                        A counted drop beats either a
                                        NULL-socket send or silent
                                        out-of-order corruption. */
        na_log(NA_LOG_ERROR, "reorder malloc failed -- record DROPPED");
        g_m4.reorder_overflow++;
        if (data) m_freem(data);
        return;
    }
    r->next = NULL;
    r->data = data;
    r->is_hole = (uint8_t)is_hole;
    if (is_hole) { memcpy(r->hole_hash, hash, MODULE4_HASH_SIZE); ms->ro_holes++; }
    if (ms->ro_tail) ms->ro_tail->next = r; else ms->ro_head = r;
    ms->ro_tail = r;
    ms->ro_count++;
    g_m4.reorder_held++;
}

/* forward a ready record: queue empty -> straight out (fast path);
 * queue non-empty -> must line up behind the hole. */
static void ro_forward(struct module1_state *ms, struct socket *so2,
                        struct mbuf *data)
{
    if (ms->ro_head == NULL) {
        if (data) tcp_usr_send(so2, data);
        return;
    }
    if (ms->ro_count >= MODULE4_REORDER_MAX) {
        /* stall too deep: abandon holes, drain everything ready, keep
         * going. This is DATA LOSS for the abandoned holes -- counted
         * and loud; it converts an unbounded-memory failure into a
         * bounded, visible one. */
        na_log(NA_LOG_ERROR, "reorder OVERFLOW (%u queued) -- abandoning %u hole(s), DATA LOSS",
               ms->ro_count, ms->ro_holes);
        g_m4.reorder_overflow++;
        while (ms->ro_head) {
            struct reorder_rec *r = ms->ro_head;
            ms->ro_head = r->next;
            ms->ro_count--;
            if (!r->is_hole && r->data) tcp_usr_send(so2, r->data);
            else if (r->is_hole) ms->ro_holes--;
            free(r);
        }
        ms->ro_tail = NULL;
        if (data) tcp_usr_send(so2, data);
        return;
    }
    ro_enqueue(ms, data, 0, NULL);
}

/* NAK-resend arrived: fill the OLDEST hole whose hash matches. */
static int ro_fill_hole(struct module1_state *ms, const uint8_t *hash,
                         struct mbuf *data)
{
    struct reorder_rec *r;
    for (r = ms->ro_head; r != NULL; r = r->next) {
        if (r->is_hole && memcmp(r->hole_hash, hash, MODULE4_HASH_SIZE) == 0) {
            r->is_hole = 0;
            r->data = data;
            ms->ro_holes--;
            g_m4.reorder_filled++;
            return 1;
        }
    }
    return 0;
}

void module4_conn_reset(struct module1_state *ms)
{
    struct reorder_rec *r;
    if (!ms) return;
    while ((r = ms->ro_head) != NULL) {
        ms->ro_head = r->next;
        if (r->data) m_freem(r->data);
        free(r);
    }
    ms->ro_tail = NULL;
    ms->ro_count = 0;
    ms->ro_holes = 0;
    ms->confirm_count = 0;
}

/* ==================== init / hello / encode ======================= */
void module4_init(void)
{
    memset(&g_m4, 0, sizeof(g_m4));
    memset(g_peers, 0, sizeof(g_peers));
}

struct mbuf *module4_build_hello(void)
{
    uint32_t gen = module2_get_generation();
    uint8_t  b[MODULE4_GEN_SIZE];
    b[0]=(gen>>24)&0xFF; b[1]=(gen>>16)&0xFF; b[2]=(gen>>8)&0xFF; b[3]=gen&0xFF;
    g_m4.total_hello_sent++;
    return build_tlv_mbuf(TLV_TYPE_HELLO, b, MODULE4_GEN_SIZE);
}

struct mbuf *module4_lookup_and_build_tlv(uint8_t *hash, uint8_t *data,
                                           uint32_t dlen, uint32_t peer_key)
{
    uint32_t cid;
    struct peer_gen_entry *e;

    if (!hash || !data || dlen == 0) return NULL;

    /* V3: below conf_min_cache_size -> RAW. No hash lookup, no store
     * write, no index entry, no cid. The inactivity timer flushes tiny
     * tails (40-200 B) that are pure loss to cache: the index entry
     * alone is ~64 B and the SHA-256 + disk write dwarf any saving.
     * Send the bytes framed and move on. */
    if (dlen < na_conf_min_cache_size()) {
        g_m4.total_raws++;
        return build_tlv_mbuf(TLV_TYPE_RAW, data, (uint16_t)dlen);
    }

    g_m4.total_lookups++;
    cid = module2_find_by_hash(hash);
    e   = peer_find(peer_key);

    /* V2 HIT condition: I have it AND peer is warm AND peer CONFIRMED
     * this exact cid. No confirmation -> MISS, even on a local hit --
     * this is what removes the wrong-HIT/NAK/reorder path entirely in
     * steady state. */
    if (cid != 0 && e != NULL && !e->is_cold && bit_test(e, cid)) {
        g_m4.total_hits++;
        module2_increment_ref(cid);
        return build_tlv_mbuf(TLV_TYPE_HIT, hash, (uint16_t)MODULE4_HASH_SIZE);
    }

    g_m4.total_misses++;
    if (cid != 0) {
        if (e && e->is_cold) g_m4.forced_miss_cold++;
        else                 g_m4.forced_miss_unconfirmed++;
    } else {
        cid = module2_store_chunk(data, dlen, hash);
    }

    {
        uint8_t p[MODULE4_CID_SIZE];
        p[0]=(cid>>24)&0xFF; p[1]=(cid>>16)&0xFF; p[2]=(cid>>8)&0xFF; p[3]=cid&0xFF;
        return build_tlv_mbuf_pfx(TLV_TYPE_MISS, p, MODULE4_CID_SIZE, data, dlen);
    }
}

/* =============== decode side ====================================== */
static void confirm_flush(struct module1_state *ms, struct socket *so1)
{
    uint8_t buf[MODULE1_CONFIRM_BATCH * MODULE4_CID_SIZE];
    int i;
    struct mbuf *c;

    if (ms->confirm_count == 0 || so1 == NULL) return;

    for (i = 0; i < ms->confirm_count; i++) {
        uint32_t cid = ms->confirm_pending[i];
        buf[i*4+0]=(cid>>24)&0xFF; buf[i*4+1]=(cid>>16)&0xFF;
        buf[i*4+2]=(cid>>8)&0xFF;  buf[i*4+3]=cid&0xFF;
    }
    c = build_tlv_mbuf(TLV_TYPE_CONFIRM, buf,
                       (uint16_t)(ms->confirm_count * MODULE4_CID_SIZE));
    if (c) { tcp_usr_send(so1, c); g_m4.confirms_sent++; }
    ms->confirm_count = 0;
}

static void confirm_queue(struct module1_state *ms, struct socket *so1,
                           uint32_t sender_cid)
{
    if (sender_cid == 0) return;
    ms->confirm_pending[ms->confirm_count++] = sender_cid;
    if (ms->confirm_count >= MODULE1_CONFIRM_BATCH)
        confirm_flush(ms, so1);
}

static void handle_record(struct module1_state *ms, struct socket *so1,
                           struct socket *so2, uint32_t rec)
{
    struct tlv_rx_state *rx = &ms->rx;
    uint8_t  type    = rx->hdr[0];
    uint8_t *val     = rx->val;
    uint32_t val_len = rx->val_need;
    uint8_t  digest[32];
    uint8_t  chunk_buf[MODULE4_CHUNK_SIZE];
    uint32_t cid, n;
    struct mbuf *raw, *nak, *miss;

    if (type == TLV_TYPE_HELLO) {
        if (val_len != MODULE4_GEN_SIZE) { printf("rec %u: bad HELLO len %u\n", rec, val_len); goto reset; }
        {
            uint32_t pg = ((uint32_t)val[0]<<24)|((uint32_t)val[1]<<16)|
                          ((uint32_t)val[2]<<8)|val[3];
            uint32_t pkey = peer_key_of(so1);
            struct peer_gen_entry *e = peer_find_or_add(pkey);
            g_m4.total_hello_received++;
            if (!e) {
                printf("HELLO: peer table full, 0x%08x stays cold\n", pkey);
            } else if (e->generation != 0 && e->generation != pg) {
                /* GENUINE CHANGE: we knew a different incarnation of
                 * this peer, so everything we believe it holds is now
                 * false. Cold + wipe the bitmap. */
                na_log(NA_LOG_WARN,
                       "peer 0x%08x generation %u -> %u (store wiped) "
                       "-- MISS-only, confirmed-set cleared",
                       pkey, e->generation, pg);
                printf("HELLO: peer 0x%08x generation %u -> %u (store wiped) "
                       "-- MISS-only, confirmed-set cleared\n",
                       pkey, e->generation, pg);
                e->generation = pg;
                e->is_cold    = 1;
                e->nak_burst  = 0;
                memset(e->confirmed, 0, sizeof(e->confirmed));
                g_m4.total_cold_transitions++;

            } else if (e->generation == 0) {
                /* FIRST SIGHTING -- do NOT mark cold.
                 *
                 * BUG THIS FIXES: cold was only ever cleared by a
                 * LATER HELLO whose generation matched. But module1
                 * sends HELLO exactly once per connection
                 * (s->hello_sent, reset only in module1_state_init),
                 * so a second HELLO never arrives on the same
                 * connection -- the peer stayed cold forever and
                 * every chunk went out as forced MISS
                 * (fmiss cold=175721, hits=0).
                 *
                 * Marking cold here bought nothing anyway: a brand
                 * new peer has an EMPTY confirmed bitmap, and the
                 * HIT rule already requires bit_test(e, cid). So the
                 * bitmap alone forces MISS until CONFIRMs populate
                 * it -- which is exactly the intended behaviour, and
                 * it self-clears as confirmations arrive. */
                na_log(NA_LOG_INFO,
                       "peer 0x%08x generation %u (first seen) -- bitmap "
                       "empty, MISS until CONFIRMs populate it",
                       pkey, pg);
                printf("HELLO: peer 0x%08x generation %u (first seen) -- "
                       "bitmap empty, MISS until CONFIRMs arrive\n",
                       pkey, pg);
                e->generation = pg;
                e->is_cold    = 0;
                e->nak_burst  = 0;

            } else {
                if (e->is_cold)
                    printf("HELLO: peer 0x%08x gen %u unchanged -- warm again\n",
                           pkey, pg);
                e->is_cold = 0;
                e->nak_burst = 0;
            }
        }

    } else if (type == TLV_TYPE_CONFIRM) {
        /* V2: arrives at the SENDER. Peer reports cids (in OUR id
         * space) it durably stored. Set the bits. */
        uint32_t pkey = peer_key_of(so1);
        struct peer_gen_entry *e = peer_find_or_add(pkey);
        uint32_t i;
        if (val_len == 0 || (val_len % MODULE4_CID_SIZE) != 0) {
            printf("rec %u: bad CONFIRM len %u\n", rec, val_len); goto reset;
        }
        if (e) {
            for (i = 0; i < val_len; i += MODULE4_CID_SIZE) {
                uint32_t c = ((uint32_t)val[i]<<24)|((uint32_t)val[i+1]<<16)|
                             ((uint32_t)val[i+2]<<8)|val[i+3];
                bit_set(e, c);
                g_m4.confirms_received++;
            }
            /* a peer that is confirming content is functional: if it was
             * cold only because it was unknown, confirms + matching gen
             * arrive via HELLO anyway; do not flip cold here. */
        }

    } else if (type == TLV_TYPE_RAW) {
        /* V3: forward as-is, store nothing, confirm nothing. Goes
         * through ro_forward: a RAW chunk is still part of the stream
         * and must never overtake an unfilled hole from an earlier
         * unresolved HIT. */
        raw = build_raw_mbuf(val, val_len);
        if (raw) { ro_forward(ms, so2, raw); ro_drain(ms, so2); }

    } else if (type == TLV_TYPE_HIT) {
        if (val_len != MODULE4_HASH_SIZE) { printf("rec %u: bad HIT len %u\n", rec, val_len); goto reset; }
        cid = module2_find_by_hash(val);
        if (cid == 0) {
            /* V2 stall-at-gap: enqueue a HOLE at the tail (stream
             * position preserved), fire NAK, DO NOT forward past it. */
            na_log(NA_LOG_WARN, "HIT unresolved -- hole+NAK (rec %u)", rec);
            g_m4.total_nak_sent++;
            ro_enqueue(ms, NULL, 1, val);
            nak = build_tlv_mbuf(TLV_TYPE_NAK, val, (uint16_t)MODULE4_HASH_SIZE);
            if (nak && so1) tcp_usr_send(so1, nak);
            goto reset;
        }
        n = module2_read_chunk(cid, chunk_buf, sizeof(chunk_buf));
        if (n == 0) { printf("rec %u: HIT read failed\n", rec); goto reset; }
        raw = build_raw_mbuf(chunk_buf, n);
        if (raw) { ro_forward(ms, so2, raw); ro_drain(ms, so2); }

    } else if (type == TLV_TYPE_MISS) {
        uint32_t sender_cid;
        uint8_t *rd;
        uint32_t rl;

        if (val_len < MODULE4_CID_SIZE + 1) {
            printf("rec %u: MISS too short (%u)\n", rec, val_len); goto reset;
        }
        sender_cid = ((uint32_t)val[0]<<24)|((uint32_t)val[1]<<16)|
                     ((uint32_t)val[2]<<8)|val[3];
        rd = val + MODULE4_CID_SIZE;
        rl = val_len - MODULE4_CID_SIZE;

        module3_compute_hash(rd, rl, digest);

        /* store locally (dedup-aware), then CONFIRM the sender's cid */
        cid = module2_find_by_hash(digest);
        if (cid != 0) module2_increment_ref(cid);
        else          cid = module2_store_chunk(rd, rl, digest);
        if (cid != 0) confirm_queue(ms, so1, sender_cid);

        raw = build_raw_mbuf(rd, rl);
        if (raw == NULL) goto reset;

        /* V2 stall-at-gap: is this MISS the resend that fills a hole?
         * Match against the oldest hole by hash. If yes it takes the
         * HOLE's stream position (not the tail), then drain. */
        if (ms->ro_holes > 0 && ro_fill_hole(ms, digest, raw)) {
            ro_drain(ms, so2);
        } else {
            ro_forward(ms, so2, raw);
            ro_drain(ms, so2);
        }

    } else if (type == TLV_TYPE_NAK) {
        if (val_len != MODULE4_HASH_SIZE) { printf("rec %u: bad NAK len %u\n", rec, val_len); goto reset; }
        cid = module2_find_by_hash(val);
        {
            uint32_t pkey = peer_key_of(so1);
            struct peer_gen_entry *e = peer_find_or_add(pkey);
            if (e) {
                if (cid != 0) bit_clear(e, cid);   /* V2: peer provably lacks it */
                e->nak_burst++;
                if (!e->is_cold && e->nak_burst >= MODULE4_NAK_COLD_THRESHOLD) {
                    printf("NAK burst (%u) from 0x%08x -- cold\n",
                           e->nak_burst, pkey);
                    e->is_cold = 1;
                    g_m4.total_cold_transitions++;
                }
            }
        }
        if (cid == 0) {
            na_log(NA_LOG_ERROR, "NAK unsatisfiable -- neither side has chunk (rec %u)", rec);
            g_m4.total_nak_unsatisfiable++;
            goto reset;
        }
        n = module2_read_chunk(cid, chunk_buf, sizeof(chunk_buf));
        if (n == 0) { g_m4.total_nak_unsatisfiable++; goto reset; }
        g_m4.total_nak_received++;
        {
            uint8_t p[MODULE4_CID_SIZE];
            p[0]=(cid>>24)&0xFF; p[1]=(cid>>16)&0xFF; p[2]=(cid>>8)&0xFF; p[3]=cid&0xFF;
            miss = build_tlv_mbuf_pfx(TLV_TYPE_MISS, p, MODULE4_CID_SIZE,
                                      chunk_buf, n);
        }
        if (miss && so1) tcp_usr_send(so1, miss);

    } else {
        printf("rec %u: unknown type 0x%02x\n", rec, type);
    }

reset:
    rx->active = 0; rx->hdr_got = 0; rx->val_need = 0; rx->val_got = 0;
}

void module4_decode_tlv_chain(struct mbuf *top, struct socket *so1,
                               struct socket *so2, struct module1_state *ms)
{
    struct mbuf *seg;
    uint8_t     *data;
    uint32_t     len, i;
    uint8_t      b;
    uint32_t     rec = 0;
    struct tlv_rx_state *rx;

    if (!top) return;
    if (!so2 || !ms) { m_freem(top); return; }
    rx = &ms->rx;

    for (seg = top; seg != NULL; seg = seg->m_next) {
        if (seg->m_len == 0) continue;
        data = mtod(seg, uint8_t *);
        len  = seg->m_len;

        for (i = 0; i < len; i++) {
            b = data[i];
            if (rx->hdr_got < 3) {
                rx->hdr[rx->hdr_got++] = b;
                if (rx->hdr_got == 3) {
                    rx->val_need = ((uint16_t)rx->hdr[1] << 8) | rx->hdr[2];
                    rx->val_got  = 0;
                    rx->active   = 1;
                    if (rx->val_need == 0 || rx->val_need > MODULE4_MAX_TLV_VAL) {
                        printf("rec %u: bad length %u, resetting\n", rec, rx->val_need);
                        rx->hdr_got = 0; rx->val_need = 0;
                        rx->val_got = 0; rx->active = 0;
                        rec++;
                    }
                }
                continue;
            }
            if (rx->val_got < rx->val_need) {
                rx->val[rx->val_got++] = b;
                if (rx->val_got == rx->val_need) {
                    handle_record(ms, so1, so2, rec);
                    rec++;
                }
            }
        }
    }

    confirm_flush(ms, so1);   /* V2: batch out whatever this call stored */
    m_freem(top);
}

void module4_get_health(struct m4_health *o)
{
    uint32_t tot;
    if (!o) return;
    tot = g_m4.total_hits + g_m4.total_misses;
    o->lookups          = g_m4.total_lookups;
    o->hits             = g_m4.total_hits;
    o->misses           = g_m4.total_misses;
    o->raws             = g_m4.total_raws;
    o->dedup_pct        = tot ? (g_m4.total_hits * 100U) / tot : 0U;
    o->nak_sent         = g_m4.total_nak_sent;
    o->nak_recv         = g_m4.total_nak_received;
    o->nak_unsat        = g_m4.total_nak_unsatisfiable;
    o->hello_sent       = g_m4.total_hello_sent;
    o->hello_recv       = g_m4.total_hello_received;
    o->cold_transitions = g_m4.total_cold_transitions;
    o->fmiss_cold       = g_m4.forced_miss_cold;
    o->fmiss_unconf     = g_m4.forced_miss_unconfirmed;
    o->confirms_sent    = g_m4.confirms_sent;
    o->confirms_recv    = g_m4.confirms_received;
    o->ro_held          = g_m4.reorder_held;
    o->ro_filled        = g_m4.reorder_filled;
    o->ro_overflow      = g_m4.reorder_overflow;
}

void module4_print_stats(void)
{
    int i;
    printf("lookups=%u hits=%u misses=%u raw=%u | nak s/r/u=%u/%u/%u | "
           "hello s/r=%u/%u cold=%u | fmiss cold=%u unconf=%u | "
           "confirm s/r=%u/%u | reorder held=%u filled=%u OVERFLOW=%u\n",
           g_m4.total_lookups, g_m4.total_hits, g_m4.total_misses, g_m4.total_raws,
           g_m4.total_nak_sent, g_m4.total_nak_received, g_m4.total_nak_unsatisfiable,
           g_m4.total_hello_sent, g_m4.total_hello_received, g_m4.total_cold_transitions,
           g_m4.forced_miss_cold, g_m4.forced_miss_unconfirmed,
           g_m4.confirms_sent, g_m4.confirms_received,
           g_m4.reorder_held, g_m4.reorder_filled, g_m4.reorder_overflow);
    printf("  my generation = %u\n", module2_get_generation());
    for (i = 0; i < MODULE4_MAX_PEERS; i++)
        if (g_peers[i].in_use)
            printf("  peer 0x%08x gen=%u cold=%u nak_burst=%u\n",
                   g_peers[i].peer_key, g_peers[i].generation,
                   g_peers[i].is_cold, g_peers[i].nak_burst);
}
