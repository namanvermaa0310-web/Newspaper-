# F-Tile Ethernet Hard IP — What Matters For This Design
### Extracted from UG 683023 (2026.08.10), scoped to a 400GE-8 MAC-segmented loopback

Organised by "what it forces you to do", not by document order.

---

## 1. CLOCKS — get this wrong and nothing else matters

**The MAC datapath clock is `o_clk_pll`, and for 400GE with KP4 FEC it is 415.0390625 MHz.**

> `i_clk_tx` — TX datapath clock. "This clock source is: `o_clk_pll` clock unless you enabled
> Enable asynchronous adapter clocks parameter"
>
> `o_clk_pll` — "415.0390625 MHz or higher for all Ethernet modes with IEEE 802.3 RS(544,514)
> (CL134)... The system PLL must be of 830.078125 MHz frequency or higher."

| Clock | Frequency | What it actually is |
|---|---|---|
| **`o_clk_pll` → `i_clk_tx`/`i_clk_rx`** | **415.0390625 MHz** (RS(544,514)/KP4) | **The MAC client datapath clock. Use this.** |
| `o_clk_pll` (no FEC / CL74 / CL91) | 402.83203125 MHz | Different FEC mode |
| `o_clk_tx_div` | 390.625 MHz | TX SERDES rate ÷ 68. **TOD/PTP use. NOT the MAC clock.** |
| `o_clk_rec_div64` | 415.0390625 MHz | RX recovered ÷ 64 |
| `o_clk_rec_div` | 390.625 MHz | RX recovered ÷ 68 |
| `i_reconfig_clk` | 100–250 MHz | CSR / Avalon-MM access |
| `i_clk_ref` | 156.25 MHz recommended | PMA reference, from F-Tile Ref & System PLL IP |

**Why the MAC interface is faster than 400 Gbps:** 1024 bits × 415.0390625 MHz = **425 Gbps of
interface capacity**, carrying 400 Gbps of payload plus idle segments for IFG and preamble. The
headroom is what makes sustained line rate deliverable. Do not "optimise" it to 390.625 MHz.

**Other clocking features to be aware of:** custom cadence (§5.6), fractional PLL mode (§5.7),
MAC asynchronous FIFO operation (§5.3), and multi-instance clock sharing (§5.2).

---

## 2. RESETS — a 12-step sequence my model does not implement at all

This is the most common cause of a link that never comes up, and it is entirely absent from the
behavioural model. **Implement this from the real IP, not from the model.**

Signals: `i_rst_n`, `i_tx_rst_n`, `i_rx_rst_n` → `o_rst_ack_n`, `o_tx_rst_ack_n`,
`o_rx_rst_ack_n`, `o_tx_lanes_stable`, `o_rx_pcs_ready`

**Bringing the IP out of reset (steps 1–3):**
1. Drive `i_rst_n` high **while `i_tx_rst_n` and `i_rx_rst_n` are already deasserted**
2. `o_rst_ack_n` deasserts — IP no longer in full reset.
   *"Note: This step doesn't indicate that the IP core is in fully functional state."*
   `o_tx_rst_ack_n` and `o_rx_rst_ack_n` also deassert, but **"The exact sequence and timing is
   not guaranteed"** — do not build logic that depends on their relative order.
3. IP fully out of reset: `o_tx_lanes_stable` and `o_rx_pcs_ready` assert.

**TX datapath reset (4–6):** assert `i_tx_rst_n` → `o_tx_lanes_stable` deasserts →
`o_tx_rst_ack_n` asserts → then deassert `i_tx_rst_n`.

**RX datapath reset (7–9):** assert `i_rx_rst_n` → `o_rx_pcs_ready` deasserts →
`o_rx_rst_ack_n` asserts.

**Practical rule:** your datapath must not drive TX until `o_tx_lanes_stable` is high. See §3.

---

## 3. STATUS INTERFACE — what gates "link is up"

All status signals except `i_stats_snapshot` are **asynchronous** — synchronise them before use.

| Signal | Meaning |
|---|---|
| `o_tx_lanes_stable` | **TX ready. `o_tx_mac_ready` is only meaningful after this asserts.** |
| `o_rx_pcs_ready` | RX datapath operational |
| `o_rx_block_lock` | Codeword alignment complete on all FEC lanes (FEC variants) |
| `o_rx_am_lock` | Alignment markers detected and PCS lanes deskewed |
| `o_rx_pcs_fully_aligned` | RX PCS ready to receive data |
| `o_local_fault_status` | RX PCS can't receive. **Only functional with MAC segmented / MAC Avalon ST client** |
| `o_remote_fault_status` | Link partner signalled it can't receive |
| `o_rx_hi_ber` | High BER state per IEEE 802.3-2015 Fig 82-15 |
| `i_stats_snapshot` | Latch statistics registers |

**From Table 43:** `o_tx_mac_ready` *"indicates the MAC is ready to receive data in normal
operational mode (i.e. After the `o_tx_lanes_stable` has asserted)."*

---

## 4. TX MAC SEGMENTED INTERFACE — the pause protocol

**Signal widths (400GE):**

| Signal | Width | Notes |
|---|---|---|
| `i_tx_mac_data` | 1024 | Bit 0 is LSB, transmitted first after SFD |
| `i_tx_mac_valid` | 1 | |
| `i_tx_mac_inframe` | 16 | 1 per segment |
| `i_tx_mac_eop_empty` | 48 | 3 per segment |
| `i_tx_mac_error` | 16 | 1 per segment |
| `i_tx_mac_skip_crc` | 16 | 1 per segment |
| `o_tx_mac_ready` | 1 | |

**The protocol — NOT ready/valid:**
> - `i_tx_mac_valid` deasserts when `o_tx_mac_ready` is deasserted.
> - `i_tx_mac_valid` asserts **only when `o_tx_mac_ready` is asserted, even though there is no
>   packet to send.**
> - The two **"can be spaced by a fixed latency between 1 to 7 clock cycles."**
> - When `i_tx_mac_valid` deasserts, all TX signals **"must be paused for as many cycles as
>   `o_tx_mac_ready` is deasserted."**

**Consequences:** an idle beat is `inframe=0`, not `valid=0`. The whole datapath freezes while
ready is low. `out_free = ~valid | ready` is the wrong protocol.

**Tight packing is mandatory for full rate:**
> *"To achieve the maximum throughput when using the TX MAC segmented interface, the input
> packets need to be packed tightly, leaving no idle segments in between."*

**`i_tx_mac_error`:** *"must be asserted for the appropriate segment in which the EOP occurs."*
Marks a completed packet invalid — useful because the MAC is cut-through and may already have
started transmitting.

**`i_tx_mac_skip_crc` — three effects at once (Table 40):**

| MAC field | `skip_crc = 0` | `skip_crc = 1` |
|---|---|---|
| Source Address | Replaced by `i_txmac_saddr` if SA Insertion enabled | Not replaced |
| Padding | Frames ≤64 B padded to 64 B | **No padding added** |
| CRC/FCS | Calculated and appended | **Not calculated — last 4 bytes of `i_tx_data` used as CRC** |

*"Must be asserted along with all valid data segments for the packet."*

**This matters directly for MACsec:** when you insert a SecTAG and ICV, you are changing frame
length and content after the original FCS. You must decide per frame whether the MAC recalculates
CRC (`skip_crc=0`) or you supply it (`skip_crc=1`). Getting this wrong produces frames that fail
FCS at the far end.

---

## 5. RX MAC SEGMENTED INTERFACE

**Signal widths (400GE):**

| Signal | Width | Notes |
|---|---|---|
| `o_rx_mac_data` | 1024 | |
| `o_rx_mac_valid` | 1 | *"When deasserted, ignore the signals value."* |
| `o_rx_mac_inframe` | 16 | 1 per segment |
| `o_rx_mac_eop_empty` | 48 | 3 per segment. *"starting from the MSB. Valid only on EOP segments."* |
| `o_rx_mac_fcs_error` | 16 | 1 per segment, valid only on EOP |
| **`o_rx_mac_error`** | **32** | **2 per segment — note the width difference vs TX** |
| `o_rx_mac_status_data` | 48 | 3 per segment |

**`o_rx_mac_error` codes (2 bits per segment):**
- `2'd0` no error (if FCS error deasserted)
- `2'd1` malformed — control character that isn't a terminate character
- `2'd2` undersized (<64 B) or oversized (> programmed max)
- `2'd3` payload length error — payload shorter than length field, length ≤ 1500

**`o_rx_mac_fcs_error`:** frame had FCS error, was malformed, undersized, or was oversized and
truncated by MTU enforcement.

**`o_rx_mac_status_data` (3 bits per segment)**, reported in priority order 5,4,7,6,1,2,3,0:
`3'd7` FC frame (type 0x8808) · `3'd6` illegal length · `3'd5` SVLAN/stacked VLAN ·
`3'd4` SFC or PFC frame · `3'd3` reserved · `3'd2` broadcast/multicast ·
`3'd1` Ethernet type, not FC · `3'd0` valid length frame

**No backpressure:** *"The interface does not take direct backpressure."*

**Multi-frame per beat:** *"Packets may start on any 8-byte segment... For multisegmented
interfaces, a new packet may start and the previous packet end are within the same cycle."*
Minimum bytes on the last cycle is 1.

---

## 6. FLOW CONTROL — the real answer to FIFO overflow

My loopback drops beats under sustained TX stall because RX takes no backpressure. **The IP has a
built-in answer to this that I did not use.**

> *"If you do not select Disable Flow Control... the F-Tile Ethernet Hard IP provides flow
> control to reduce congestion at the local or remote link partner... PAUSE frames instruct the
> remote transmitter to stop sending data for the duration that the congested receiver specified
> in an incoming XOFF frame. PFC frames instruct the receiver to halt the flow of packets
> assigned to a specific Priority Queue."*

Sections: 4.2.3.1 XOFF triggering, 4.2.3.2 XON triggering, 4.2.3.3 pause control and generation
interface, 4.2.3.4 pause control frame filtering.

**Action:** for a production encryptor, wire the pause generation interface to your FIFO
occupancy rather than silently dropping. Dropping frames in a MACsec device also breaks the
replay window at the far end.

---

## 7. INTER-PACKET GAP

> *"The MAC RX removes all IPG octets received, and does not forward them to the client
> interface. For 10GE/25GE rates, it can sustain a stream with IPG of 5. For rates higher than
> 25GE, it can tolerate a sustained stream of packets with an IPG of 1."*

At 400G the RX tolerates **IPG of 1** sustained. Your model should generate at least that
density to be a realistic worst case.

---

## 8. FRAME FIELD POSITIONS

Byte order is LSB→MSB. `i_tx_mac_data[7:0]` is the first octet after SFD (destination address
unicast/multicast bit).

| Bytes | Field |
|---|---|
| [7:0]–[47:40] | Dest Addr [47:40] → [7:0] |
| [55:48]–[95:88] | Src Addr [47:40] → [7:0] |
| [103:96]–[111:104] | Length/Type [15:8], [7:0] |
| [112:] | Payload |

**Preamble Passthrough:** if enabled, you must supply **8 preamble bytes** to the TX segmented
interface, and the field offsets shift. Decide this at IP generation.

---

## 9. THINGS IN THE DOCUMENT THAT WILL MATTER LATER

| Section | Why it will matter |
|---|---|
| **4.4 Precision Time Protocol** (48–79) | If PTP is ever added: TX/RX client flow, virtual lane offsets, UI adjustment, TAM intervals, routing delay for basic vs advanced timestamp accuracy |
| **4.2.4 Link Fault Signaling** | Local/remote fault handling for a defence link that must report loss |
| **4.5 Auto-Negotiation and Link Training** | Required for backplane/copper; not for most optical |
| **5.6 Custom Cadence** | Non-standard clock ratios |
| **5.3 MAC Asynchronous FIFO** | If TX and RX clocks genuinely differ |
| **8. Configuration Registers** (161) | Statistics counters, MTU config, pause config — all via `i_reconfig_clk` Avalon-MM |
| **7.2/7.3 Avalon-ST client** | The alternative client interface — **not available at 400GE**, but relevant if you ever build a 100G-only variant |

---

## 10. STILL UNRESOLVED

**How is EOP located when frames are packed tightly?**

§7.4 says EOP is an `i_tx_mac_inframe` transition from 1 to 0 between consecutive segments. But
§7.4 also mandates tight packing with no idle segments — under which `inframe` stays high across
a frame boundary, so no such transition exists. §7.5 has the same contradiction and additionally
refers to an *"`o_rx_mac_eop_empty` transition from 1 to 0"*, which does not typecheck against
`eop_empty` being a 3-bit-per-segment count.

Both statements cannot be literally true. **Resolve from the IP's generated design example, or
from Figures 41 and 43 viewed as actual waveforms.**

Impact: none on the current beat-level datapath (it is frame-agnostic). It becomes blocking the
moment you add SecTAG insertion or ICV placement, because those are frame-aware.

---

## 11. GAP LIST — what the behavioural model does NOT implement

Present this alongside any simulation result:

- Reset sequencing and all six reset/ack signals (§2 above)
- All status signals — link-up gating, fault, BER, alignment
- PMA, PCS, RS-FEC (KP4), lane distribution, gearbox, CDR, AM lock, AN/LT
- PAUSE/PFC flow control
- `skip_crc` semantics (SA insertion, padding, CRC substitution)
- Statistics registers and CSR/Avalon-MM
- PTP/TOD
- Preamble passthrough mode
- MTU enforcement and the resulting truncation/error reporting
