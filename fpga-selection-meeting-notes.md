# FPGA Selection — Discussion Notes
### 100G MACsec Link Encryptor | Meeting with Manager

---

## 1. Proposed outcome of this meeting

Not a final part number. We do not yet have the inputs to fix one responsibly.

**Proposed outcome instead:**
1. Agree a **shortlist of 2 candidate devices**
2. Agree the **3 inputs** needed to choose between them
3. Approve a **development kit purchase now**, so RTL work starts in parallel
4. Agree the **board strategy** (in-house custom vs dev-kit/COM first article)

Fixing an OPN today on incomplete requirements means redoing schematic work later.

---

## 2. What Agilex 7 is — short introduction

Altera's (formerly Intel) current high-end FPGA family, on 10 nm SuperFin. Successor
to Stratix 10.

**Key architectural point: it is not a single chip.** It is a chiplet package:
- One main **FPGA fabric die**
- **1 to 6 hardened transceiver tiles**, as separate dies
- Connected by **EMIB** (Embedded Multi-die Interconnect Bridge)

This matters because *the tile — not the logic capacity — is what we are actually selecting.*

### Three series

| Series | Positioning | Relevance to us |
|---|---|---|
| **F-Series** | Mainstream high-end | **Primary candidate** |
| **I-Series** | Higher I/O performance, PCIe 5.0, CXL, up to 116 Gbps | Only if host PCIe attach is required |
| **M-Series** | HBM2e memory, compute-heavy workloads | Not applicable |

### Transceiver tiles — the real decision

| Tile | Max Ethernet | Lane rate | Board difficulty |
|---|---|---|---|
| **E-Tile** | 100GE (hard IP ceiling) | 28.9G NRZ | Moderate |
| **F-Tile** | 10G to **400GE** | 106.25G PAM4 | High |
| P-Tile / R-Tile | none (PCIe / CXL only) | — | — |

---

## 3. Why Agilex 7 and not Stratix 10

Worth stating explicitly if Stratix 10 is on the table:

| | Stratix 10 | Agilex 7 |
|---|---|---|
| Hard Ethernet MAC | 100G max (E-Tile) | 100G (E-Tile) / **400G (F-Tile)** |
| Hardened AES-GCM crypto | **None** | 200G half-duplex on specific OPNs |
| MACsec reference design | No | **Yes** — Altera MACsec FPGA System Design |
| Fabric performance | Previous generation | ~40% improvement |
| Product lifecycle | Mature / late-life | Current |

For a new programme with a multi-year field life, selecting the previous generation
needs justification.

---

## 4. The two candidates

### Candidate A — Agilex 7 F-Series with **E-Tile**
- 100GE via 4 × 25.78G **NRZ**
- Lower board risk — NRZ signal integrity is significantly easier than PAM4
- Lower device cost, wider package choice
- **Hard ceiling at 100G. No upgrade path.**

### Candidate B — Agilex 7 F-Series or I-Series with **F-Tile**
- 100GE now, upgrade path to 200G/400G on the same board design
- Altera's **MACsec reference design** is built on Agilex 7 I-Series + F-Tile
  — we start from working architecture instead of from zero
- Supports Deficit Idle Counter for IPG control (needed for MACsec frame expansion)
- **Higher board risk** — PAM4 channels need proper SI simulation and backdrilled HDI

### Recommendation
**Candidate B (F-Tile)** — *if* we can resource the signal integrity work.
The customer already floated 400G once. Designing a board with no headroom is a
predictable future problem.
**Candidate A** only if 100G is contractually final and board risk must be minimised.

---

## 5. Three inputs we need before fixing the OPN

**These are the blockers. Requesting management help to obtain them.**

1. **Customer requirement document.** Specifically:
   - Single 100G port or multiple?
   - 100G full-duplex confirmed?
   - Environmental / temperature grade → *this eliminates OPNs outright; not every
     density-package-tile combination is offered in every grade*
   - Latency budget
   - Frame size profile (line rate at 64-byte frames, or an IMIX?)
   - Cipher suite
   - Certification scope (FIPS 140-3 / CAVP?)
   - Host interface required? → if PCIe, the package must include P-Tile or R-Tile,
     which changes the device entirely

2. **Procurement feasibility.** Lead time and export/end-use clearance for the candidate
   OPNs. Agilex 7 lead times on non-mainstream part numbers can exceed a year, and defence
   procurement adds licensing on top. **A schematic built around an unobtainable OPN is a
   total loss.** Need this checked before design commitment, not after.

3. **Board strategy decision** (see §7).

---

## 6. Two technical issues to raise now, not later

### 6.1 Packet Number exhaustion — likely specification defect

MACsec with a standard 32-bit packet number. Reusing a packet number under the same key
is a catastrophic AES-GCM failure — it leaks the authentication key.

At 100G with 64-byte frames: **the 32-bit counter wraps in approximately 29 seconds.**

Rekeying every 29 seconds is not viable. We must use **GCM-AES-XPN-256** (64-bit extended
packet number). If the customer specification names plain GCM-AES-256, we should raise it
in writing as a defect.

### 6.2 Bitstream security

The FPGA configuration bitstream can be authenticated and encrypted via the Secure Device
Manager. **For a cryptographic product this is not optional** — an encryptor whose bitstream
can be substituted is not an encryptor.

This must be scoped now because it affects key provisioning, the production programming
flow, and possibly the certification path.

---

## 7. Board strategy — the decision that most affects schedule

An Agilex 7 custom board is a different class of work from our previous Cyclone IV E /
Cyclone 10 LP boards:

| | Cyclone 10 LP board | Agilex 7 board |
|---|---|---|
| Layers | 4–6 | 16–24, HDI |
| BGA balls | ~250 | 1600–2900 |
| Power rails | 2–3 | 10+, monotonic ramp, strict sequencing |
| Regulator | Standard LDO/buck | **PMBus-compliant SmartVID** — wrong choice = device never configures |
| High-speed routing | None | Backdrilled, impedance-controlled, SI-simulated |
| Typical schedule | 2–3 months | **12–18 months with a dedicated hardware team** |

### Recommended approach: parallel, not serial

**Phase 1 (start now):** Development kit. Develop and prove the MACsec RTL, confirm timing
closure and resource fit at 100G. Dev kit schematics are published — they give us a
validated reference power tree, SmartVID regulator circuit, SDM configuration circuit,
and QSFP front-end to base the custom board on.

**Phase 2:** Custom board, designed by copying the proven reference, with SI support.

**Risk if we go serial:** ~12 months of RTL development idle behind board bring-up, and we
discover fit/timing problems only after silicon is committed.

---

## 8. Resource questions to put to management

1. **Development kit purchase approval** — the single highest-leverage spend on this project.
2. **Signal integrity capability** — do we have SI simulation tooling and expertise in-house?
   If not, this must be bought in or contracted. This is the top schedule risk.
3. **PCB fabrication** — do we have a qualified vendor for 20+ layer HDI with backdrilling?
4. **Hardware design ownership** — I am currently expected to do both the MACsec RTL and the
   board schematic. These are two full-time roles with different skill sets. Request a
   dedicated hardware engineer for board design.
5. **Is the custom board a programme/indigenisation mandate, or an engineering choice?**
   If mandated, we should still deliver the first article on a dev kit to de-risk, and
   treat the custom board as a properly resourced phase two.

---

## 9. Top risks — one-line summary

| Risk | Impact |
|---|---|
| SmartVID regulator or PMBus mode wrong | Board does not configure. Respin, not a firmware fix. |
| Custom board attempted without SI capability | Multi-month schedule loss, possible multiple respins |
| Selected OPN unobtainable / export-blocked | Total design loss |
| Cipher suite spec defect (no XPN) | Cryptographic failure; rework late in programme |
| Frame expansion / IPG policy not agreed | Silent packet drops discovered at acceptance testing |
| Fixed-voltage device chosen | Locks us to slowest (−4) speed grade; timing closure risk |
| Serial schedule (RTL waits for board) | ~12 months lost |

---

## 10. Asks — summary

1. Approve **development kit purchase** this month
2. Support obtaining the **customer requirement document**
3. Initiate **procurement/lead-time check** on candidate OPNs
4. Decide **custom board vs dev-kit first article**
5. Confirm **SI and PCB layout resourcing**
6. Agree **who owns board design** — RTL and hardware are separate roles
