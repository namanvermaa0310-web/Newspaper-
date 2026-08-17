# Agilex 7 — Complete Reference for a 100G MACsec Link Encryptor

Scope: everything you need to know about Agilex 7 in the specific context of building
a 100 Gbps MACsec (IEEE 802.1AE) link encryptor, including custom board design.

---

## 0. Read this part first

Three statements you should treat as project constraints, not opinions:

1. **Device selection must happen before schematic capture, and it is driven by the
   transceiver tile, not by logic density.** Logic capacity is almost never the binding
   constraint on a 100G MACsec design. Tile type, transceiver count, and whether the
   OPN carries hardened crypto are.

2. **A custom Agilex 7 board is a hardware-team project, not an RTL-engineer side task.**
   Expect 16–24 layer HDI, controlled-impedance differential routing with backdrilling,
   10+ power rails with monotonic sequencing requirements, a PMBus-compliant SmartVID
   regulator, and a BGA in the 1600–2900 ball range. Compare this honestly against your
   prior Cyclone IV E / Cyclone 10 LP boards.

3. **Development kit first, custom board second, in parallel — never serial.** The dev
   kits ship with published schematics. Those schematics are your reference power tree,
   SDM configuration circuit, and QSFP front-end. Copying a proven reference is the single
   largest risk reduction available to you.

---

## 1. Architecture: what an Agilex 7 device physically is

Agilex 7 is **not a monolithic die.** It is a chiplet package:

- One **main FPGA fabric die**, built on Intel 10 nm SuperFin.
- Between **one and six hardened transceiver tiles**, as separate dies.
- On M-Series, optionally **HBM2e stacks**.
- All connected to the fabric die by **EMIB** (Embedded Multi-die Interconnect Bridge).

**Why this matters to you directly:**

- The tile is a *different piece of silicon* with its own power rails, its own reset and
  calibration sequence, and its own initialization firmware. Your power tree and your
  bring-up sequence both have tile-specific requirements.
- The **EMIB Deskew block** sits between the tile and fabric and corrects skew across the
  EMIB interface. You do not control this, but it contributes latency — relevant if your
  customer has a latency budget.
- Different OPNs in the same package can carry different tile combinations. The package
  does not tell you what you have. **The OPN does.**

### The tile types

| Tile | Max lane rate | Ethernet support | Primary use |
|------|---------------|------------------|-------------|
| **E-Tile** | 58G PAM4 / 28.9G NRZ | Hard IP up to **100GE** | 10/25/100G Ethernet |
| **F-Tile** | 106.25G PAM4 / 32G NRZ | Hard IP **10G to 400GE** | 100/200/400G Ethernet, PCIe Gen5 |
| **P-Tile** | — | none | PCIe Gen4, CXL |
| **R-Tile** | — | none | PCIe Gen5, CXL 2.0 |

For a **100G MACsec encryptor, both E-Tile and F-Tile work.** This is a real decision,
covered in §3.

### The three series

| Series | Positioning | Notes for you |
|--------|-------------|---------------|
| **F-Series** | Mainstream. E-Tile + P-Tile, or F-Tile variants. | **Most likely correct choice for 100G.** |
| **I-Series** | High-performance I/O. Up to 116 Gbps transceivers, PCIe 5.0, CXL. | Overkill for 100G unless you need CXL/PCIe Gen5 host attach. |
| **M-Series** | HBM2e, DDR5, hardened memory NoC. Up to 3.9M LE, 116 Gbps. | Wrong tool. This is for memory-bound compute, not link encryption. |

Reference data points:
- F-Series **AGFB027** (used on the F-Series 2× F-Tile dev kit): 2.69M LE, 3.65M ALM,
  8.5K DSP blocks, 2340A BGA package, quad-core Arm Cortex-A53 HPS, 0.8 V VID-adjustable VCC.
- F-Series **AGFB014R24B2E2EV** (Transceiver-SoC dev kit): 1400K LE, 400K ALM, 36 Mb eSRAM,
  4510 DSP, 24 PAM4 / 32 NRZ on F-Tiles, one P-Tile PCIe controller, 12 PAM4 / 24 NRZ on E-Tiles.

Note the second part: **it carries both E-Tiles and F-Tiles.** Mixed-tile devices exist.
Do not assume a device has one tile type.

---

## 2. Decoding the OPN — the most important 14 characters in the project

The part number encodes series, density, tile configuration, package, speed grade,
power option, and temperature range. The authoritative decoder is in the
**Agilex 7 FPGAs and SoC FPGAs Package, Pinout, and PCB Design User Guide**, section
"Part Number Decoder."

Illustrative breakdown of `AGFB014R24B2E2EV`:

```
AG   F    B    014   R24B2   E2   E   V
|    |    |    |     |       |    |   |
|    |    |    |     |       |    |   +-- Power option (V = SmartVID)
|    |    |    |     |       |    +------ Temperature grade (E = Extended)
|    |    |    |     |       +----------- Speed grade
|    |    |    |     +------------------- Package / tile configuration code
|    |    |    +------------------------- Logic density (K LE)
|    |    +------------------------------ Fabric / feature variant (B = with HPS)
|    +----------------------------------- Series (F / I / M)
+---------------------------------------- Agilex family
```

### Suffixes you must get right

**Power option suffix** — determines whether the device needs SmartVID:
- **`-V`, `-E`, `-X`** → **SmartVID device.** Requires a PMBus-compliant regulator.
- **Fixed-voltage devices** → no SmartVID, **but only available in the −4 speed grade.**

> **This is a trap for your project.** The −4 speed grade is the slowest offering.
> A 100G MACsec datapath at 512 bits × ~200–400 MHz, with AES-GCM and GHASH in the
> critical path, may not close timing on −4. If you pick a fixed-voltage part to simplify
> the power design, you may pay for it in months of timing closure. Budget the power
> complexity instead.

**Temperature grade** — for a defense product, confirm whether Industrial or Extended
grade is required by the environmental spec, and confirm that grade exists for your
chosen density/package/tile combination. Not all combinations are offered.

**Action item:** get the exact OPN written into the design document before schematic
capture starts. Every downstream decision — pinout, power tree, thermal solution,
Quartus device selection — depends on it.

---

## 3. Choosing the tile for 100G MACsec

This is your main open engineering decision.

### Option A: E-Tile

**Pros**
- Hard Ethernet IP natively supports 10G / 25G / 100G.
- Mature, well-documented, large body of existing designs.
- Lower cost devices, more package options.
- 100GE via 4× 25.78125 Gbps NRZ (100GAUI-4) — NRZ signal integrity is materially easier
  than PAM4 on a custom board.

**Cons**
- Hard ceiling at 100G. Zero headroom if the customer later asks for 200G or 400G.
- Older tile generation.

### Option B: F-Tile

**Pros**
- Supports 10G through 400GE. Direct upgrade path — this matters given your customer
  originally floated 400G.
- Supports 100GE-1, 100GE-2, 100GE-4 — you can run 100G over one, two, or four lanes.
- Altera's **MACsec FPGA System Design** reference is built on Agilex 7 I-Series with F-Tiles.
  Starting from a working reference design is a large schedule saving.
- Deficit Idle Counter (DIC) support for controlled 8/10/12-byte minimum average IPG —
  directly relevant to MACsec frame expansion (see §7).

**Cons**
- PAM4 at 53.125 / 106.25 Gbps demands serious signal integrity work on a custom board:
  channel loss budgeting, backdrilling, via optimization, insertion-loss simulation.
- **No Avalon-ST client interface at 200GE/400GE** — segmented interface only. At 100GE
  this is less of an issue, but design for segmented if you want the 400G upgrade path.

### Recommendation

**F-Tile**, if the customer roadmap has any chance of exceeding 100G, and if you can get
proper SI support for the PAM4 channels. **E-Tile**, if 100G is genuinely final and you want
to minimize board risk. Do not choose on price alone — the tile decision is effectively
irreversible after layout.

---

## 4. Power architecture — where custom Agilex 7 boards most often fail

### 4.1 SmartVID

SmartVID compensates for silicon process variation by adapting the core voltage per device.
It is **managed by the Secure Device Manager (SDM)**, not by the fabric.

Sequence of events at power-up:
1. VCC and VCCP ramp to 0.8 V.
2. The SDM subsystem powers up.
3. The **SDM Power Manager** reads the factory-programmed SmartVID value from the device.
4. It communicates that value to the external regulator over **PMBus**.
5. The regulator adjusts VCC and VCCP to the device-specific optimal level.
6. The SDM configures the FPGA and transitions it to user mode.
7. During operation, the SDM monitors temperature and updates VCC/VCCP accordingly.

**Regulator requirements (from the Agilex 7 Power Management User Guide):**

| Parameter | Specification |
|-----------|---------------|
| Voltage range | 0.6 V – 1.0 V |
| Voltage step | 5 – 10 mV |
| Ramp time (non-CvP) | 10 mV per 10 ms → 10 mV per 20 µs |
| Ramp time (CvP) | 10 mV per 60 µs → 10 mV per 20 µs |

**PMBus operating mode must be chosen before board design:**
- **PMBus Master mode** — FPGA is master. Supports multi-master. **1.8 V single-ended I/O only.**
  Supported output format: VID mode.
- **PMBus Slave mode** — FPGA is slave. Supports Linear and Direct format
  (Direct with coefficients m=1, b=0, R=0, output in mV).

**Failure modes to take seriously:**
- Wrong PMBus mode wired on the board → **device will not configure.** Not a firmware fix.
- Wrong regulator coefficient values entered in Quartus → regulator supplies the wrong
  voltage → **configuration failure**, or silicon damage.
- Non-PMBus-compliant regulator → device never leaves the SDM power-manager stage.

**Mandatory reading before you draw the power schematic: AN 974 — "Agilex 7 and Stratix 10
SmartVID Debug Checklist and Voltage Regulator Guidelines."** This document exists precisely
because this circuit is the most common cause of dead Agilex boards.

Also use the **Enpirion Power Resource Center power tree selector** — it gives validated
regulator combinations per device, which is far safer than selecting parts yourself.

### 4.2 Power sequencing

Hard requirements from the Power Management User Guide:

- **All rails must ramp up and ramp down monotonically.** No plateaus, no dips, no
  non-monotonic behavior anywhere in the ramp.
- The power-up sequence must meet the **POR delay time** (see the F-Series/I-Series Device
  Data Sheet, "POR Specifications").
- **For CvP: total tRAMP < 10 ms** from first rail ramp to last rail ramp.
- **Power-down: all rails fully down within 100 ms.**
- Devices with **E-Tile have their own additional power-down sequence requirements** —
  a separate section in the user guide. Do not assume the F-Tile sequence applies.
- POR delay includes the boot ROM initialization sequence.

### 4.3 The separate I/O voltage domains

Three independent VCCIO domains with distinct sequencing behavior:

| Domain | Powers | During ramp, unpowered banks are |
|--------|--------|----------------------------------|
| **VCCIO_SDM** | Configuration / SDM pins. Typically **1.8 V**. | tri-stated, driven to GND, or driven to VCCIO_SDM |
| **VCCIO_PIO** | General-purpose I/O banks | tri-stated, driven to GND, or driven to VCCIO_PIO |
| **VCCIO_HPS** | HPS I/O banks | tri-stated, driven to GND, or driven to VCCIO_HPS |

**Critical board-level rule:** during the window where VCCIO_SDM is up (1.8 V) but
VCCIO_PIO has not yet ramped, **any external device driving an SDM I/O pin must not exceed
1.8 V.** If your MAX 10 / configuration controller / BMC drives SDM pins at 2.5 V or 3.3 V,
you can damage the part. Level-shift or match the rail.

### 4.4 Power estimation and thermal

Use in this order, as the design matures:
1. **Power and Thermal Calculator (PTC)** — early estimate, before RTL exists.
2. **Quartus Power Analyzer** — post-fit, accurate.
3. **Compact Thermal Models (CTM)** — for heat sink and airflow design.
4. **Temperature Sensing Diodes (TSD)** — for remote temperature sensing on the board.

Agilex 7 with active transceivers is not a passively-cooled device in most enclosures.
For a rugged/sealed defense chassis, do the thermal work **before** you commit to a
mechanical envelope — this has killed more defense FPGA programs than timing closure ever has.

---

## 5. Configuration and the Secure Device Manager

The SDM is a fundamental architectural difference from Cyclone. There is no simple
nCONFIG/CONF_DONE/nSTATUS model anymore. The SDM is a hardened, secure microcontroller
that owns power management, configuration, authentication, and remote system update.

### Configuration schemes

| Scheme | Notes |
|--------|-------|
| **Avalon-ST x8 / x16** | Host-driven (MAX 10, CPU, BMC). Fastest. Dev kits use x16 with dual 2 Gb flash. |
| **Active Serial (AS) x4** | Quad-SPI flash. Simplest. Dev kits use 2 Gb flash. |
| **JTAG** | Development and debug. Always provide a header. |
| **CvP** | Configuration via PCIe. Only relevant if you have a host interface. |

### Board items you must get right

- **MSEL straps** — select the configuration scheme. Wrong straps = no boot.
- **SDM pin mapping** — which SDM_IO pin carries which function is assigned in Quartus QSF
  and must match the board. Example from the F-Series dev kit:
  ```
  set_global_assignment -name USE_PWRMGT_SCL  SDM_IO14
  set_global_assignment -name USE_PWRMGT_SDA  SDM_IO11
  set_global_assignment -name USE_CONF_DONE   SDM_IO16
  set_global_assignment -name ACTIVE_SERIAL_CLOCK AS_FREQ_100MHZ
  set_global_assignment -name PWRMGT_SLAVE_DEVICE0_ADDRESS 47
  ```
  These assignments are **board-dependent constants.** Capture them in your design document
  alongside the schematic.
- **Remote System Update (RSU)** — for a fielded defense encryptor you almost certainly want
  RSU with a factory-image fallback. Design the flash partitioning for it from the start;
  retrofitting is painful.
- **Configuration bitstream authentication and encryption** — the SDM supports authenticated
  and encrypted bitstreams with key storage. **For a cryptographic product this is not
  optional.** An encryptor whose bitstream can be replaced is not an encryptor. Scope this
  into the requirements now: it affects key provisioning, production programming flow,
  and possibly your certification path.

---

## 6. Hardened crypto — verify, do not assume

Certain Agilex 7 OPNs include **hardened AES-GCM crypto engines rated at 200 Gbps
half-duplex**, paired with MACsec IP. Reported SKUs include AGF023, AGF019, AGI023, AGI019.

**What this means for a 100G full-duplex encryptor:**
- 100G full duplex = 100 Gbps encrypt + 100 Gbps decrypt = 200 Gbps aggregate.
- One 200G half-duplex hard engine covers **one direction only**. You need **two**.
- Verify against the specific OPN datasheet how many crypto blocks that device contains.

**Do not select a device on the assumption that hardened crypto is present.** Get it
confirmed in writing from Altera or your distributor against the exact OPN, in the exact
package, in the exact speed and temperature grade, before the schematic is released.

**Fallback:** soft AES-GCM in fabric. At 100G this is entirely feasible — a 512-bit datapath
at ~200 MHz gives 102.4 Gbps. That needs 4 pipelined AES-256 cores per direction plus a
4-way Karatsuba GF(2^128) GHASH. Well within Agilex 7 fabric. Plan the soft path as your
baseline and treat hardened crypto as an optimization, not a dependency.

---

## 7. MACsec-specific design constraints

These are independent of device selection but must be settled before RTL and before you
size the fabric.

### 7.1 Cipher suite — XPN is effectively mandatory

MACsec cipher suites: GCM-AES-128, GCM-AES-256, GCM-AES-XPN-128, GCM-AES-XPN-256.

The non-XPN suites use a **32-bit packet number**. GCM catastrophically fails on nonce
reuse — repeating a PN under the same SAK leaks the authentication key.

Time to PN exhaustion at 100G:

| Frame size | Approx. rate | 32-bit PN wraps in |
|-----------|--------------|--------------------|
| 64 B | ~148.8 Mpps | **~29 seconds** |
| 512 B | ~23.5 Mpps | ~3 minutes |
| 1522 B | ~8.1 Mpps | ~9 minutes |

Rekeying every 29 seconds is not a viable design. **Use GCM-AES-XPN-256** (64-bit extended
packet number). If the customer specification names plain GCM-AES-256, raise it as a
specification defect in writing, with the numbers above.

### 7.2 Frame expansion and the IPG problem

Every MACsec frame grows:
- **SecTAG**: 8 bytes (without SCI) or 16 bytes (with SCI)
- **ICV**: 16 bytes
- **Total growth: 24 or 32 bytes per frame**

At 100% ingress line rate with minimum-size frames, you **physically cannot** insert those
bytes on egress. Options:
1. Accept a small drop rate at 100% utilization with minimum frames.
2. Use **DIC (Deficit Idle Counter)** to control average IPG — the F-Tile Ethernet hard IP
   supports 8, 10, or 12 byte minimum average IPG, or lets you drive IPG directly.
3. Run the internal datapath faster than line rate to absorb the expansion.
4. Specify a frame-size mix (IMIX) with the customer rather than worst-case minimum frames.

**Pick one and get it agreed with the customer.** The default failure mode is silent drops
discovered during acceptance testing.

### 7.3 Other items to lock down before RTL

- **Key management**: MKA/802.1X, or externally provisioned SAKs? Defense links usually use
  external/custom key provisioning — less work, but you need a key-load interface and a
  rekey protocol.
- **Number of SecY / SC / SA instances**: one SA per direction is simple. Multi-SC with
  TCAM classification is a substantially larger design.
- **Confidentiality offset**: 0, 30, or 50 bytes. Affects whether headers stay in clear.
- **Latency budget**: cut-through vs store-and-forward. Store-and-forward is far simpler
  for GCM (you know the length before you emit) but costs latency.
- **Certification**: FIPS 140-3 / CAVP in scope? If yes, this dominates the schedule and
  constrains your AES-GCM implementation. Find out now.

---

## 8. Board design in OrCAD — the actual workflow

### 8.1 Order of operations

1. **Lock the OPN.** Nothing else can start.
2. **Download the Pin Connection Guidelines** for that device family. This is the normative
   document for every power pin, every unused pin, every required tie.
3. **Do pin planning in Quartus, not in Capture.** Create the project, select the device,
   instantiate the F-Tile/E-Tile Ethernet IP and any EMIF, assign I/O standards per bank,
   run Pin Planner and I/O Assignment Analysis. **Export the `.pin` file.**
   Board-first pin assignment on a 2000+ ball device guarantees rework.
4. **Generate the OrCAD symbol from the `.pin` file by script.** Never hand-enter it.
   Split into a heterogeneous multi-part symbol:
   - Part A: Power (VCC, VCCP, VCCIO_*, VCCH_*, VCCA_*) and GND
   - Part B: SDM / configuration
   - Part C: HPS (if SoC variant)
   - Part D: each GPIO bank as its own part
   - Part E: each transceiver tile as its own part
   A single monolithic 2000-pin symbol is unreadable and unreviewable.
5. **Schematic capture in OrCAD Capture.**
6. **Schematic review against Altera's Schematic Review Worksheet** — this is a published
   checklist in the Package, Pinout, and PCB Design User Guide, section 6.9. Use it verbatim.
7. **Stackup and SI simulation before layout.** Channel loss budget for every transceiver
   lane. This is HyperLynx / ADS / Sigrity territory, not something you eyeball.
8. **Layout in Allegro / PCB Editor.**
9. **PDN simulation.** Decoupling network verified against target impedance, not
   rule-of-thumb capacitor counts.
10. **Post-layout SI verification and backdrill definition.**

### 8.2 What OrCAD Capture does and does not cover

- **Capture** = schematic only. It will happily let you produce an electrically correct
  schematic that is physically unroutable at this ball pitch and lane rate.
- The real risk is in **layout and SI**. If your team does not have SI simulation capability
  and a fab partner qualified for HDI with backdrilling, that gap is a bigger schedule risk
  than any RTL problem in this project.

### 8.3 Altera resources that map directly to schematic work

From the **Agilex 7 FPGAs and SoC FPGAs Package, Pinout, and PCB Design User Guide**:

| Section | Content |
|---------|---------|
| 2.2 | Part Number Decoder |
| 2.3 | Series / Package / Tile Comparison Table |
| 2.4 | Migration within a Package |
| 2.5 | Series Package Options vs Tiles — supported I/O counts |
| 3.1.1–3.1.3 | Package mechanical drawings, ball coordinates, **PCB footprints** |
| 3.1.4 | Land pattern PCB design recommendations |
| 4.x | Thermal: power estimation, CTM, heat sink, TSD |
| 5.1 | **Pin Connection Guidelines** |
| 5.3 | I/O banks — GPIO, SDM I/O, HPS I/O |
| 6.1 | **Schematic symbols** |
| 6.2 | Power supply |
| 6.4.2.1 | **F-Tile transceivers** |
| 6.7 | FPGA configuration |
| 6.8 | **Development kit examples** |
| 6.9 | **Schematic Review Worksheet** |
| 6.10 | Step-by-step generic PCB design flow |
| 7 | **Signal integrity simulations** |

Section 6.10 is literally a step-by-step board design flow written by the vendor. Follow it.

---

## 9. Document set to download now

| Document | Why |
|----------|-----|
| Agilex 7 Device Design Guidelines | Top-level planning document |
| Agilex 7 FPGAs and SoC FPGAs Package, Pinout, and PCB Design User Guide | Board design bible |
| Agilex 7 Device Family Pin Connection Guidelines | Normative pin-by-pin requirements |
| Agilex 7 Power Management User Guide | SmartVID, sequencing, PDN |
| **AN 974** — SmartVID Debug Checklist and Voltage Regulator Guidelines | Prevents dead boards |
| Agilex 7 Configuration User Guide | SDM, MSEL, config schemes, RSU |
| Agilex 7 FPGAs and SoCs Device Data Sheet: F-Series and I-Series | POR specs, tRAMP, operating conditions |
| F-Tile Ethernet Intel FPGA Hard IP User Guide | 100GE/400GE hard IP, segmented interface, DIC |
| E-Tile Ethernet Intel FPGA Hard IP User Guide | If you choose E-Tile |
| F-Tile Architecture and PMA/FEC Direct PHY IP User Guide | Transceiver configuration |
| MACsec FPGA System Design User Guide (Agilex 7 I-Series, F-Tile) | The reference design |
| Relevant development kit User Guide + schematics | Reference power tree and config circuit |

---

## 10. Risk register

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | Custom board attempted without SI/PI capability | **Critical** | Use dev kit or COM module for first article; engage SI specialist for custom board |
| 2 | SmartVID regulator wrong or PMBus mode wrong | **Critical** | AN 974 + Enpirion power tree selector; review before schematic release |
| 3 | Fixed-voltage device chosen → stuck at −4 speed grade → timing closure fails | High | Choose SmartVID part; budget the power complexity |
| 4 | Hardened crypto assumed but absent on chosen OPN | High | Confirm in writing per OPN; design soft AES-GCM as baseline |
| 5 | Spec calls for GCM-AES-256 without XPN | High | Raise as spec defect with PN-exhaustion numbers |
| 6 | Frame expansion / IPG behaviour not agreed with customer | High | Agree drop policy or IMIX in writing before acceptance test |
| 7 | Bitstream authentication not scoped | High | Required for a crypto product; affects production flow and certification |
| 8 | Thermal envelope fixed before power analysis | High | Run PTC early; do thermal before mechanical freeze |
| 9 | Pin assignment done board-first | Medium | Quartus Pin Planner → `.pin` → symbol |
| 10 | 400G scope creep returns | Medium | Choose F-Tile now to preserve the upgrade path |

---

## 11. Immediate next actions

1. Confirm the exact **OPN** (series, density, tile config, package, speed grade, power suffix,
   temperature grade).
2. Confirm whether BEL is committed to an **in-house custom board** or whether a dev kit /
   COM module is acceptable for the first article.
3. Get the **customer requirement document** and extract: cipher suite, key management model,
   number of SAs, latency budget, frame-size profile, certification scope, environmental grade.
4. Order the **development kit** and start MACsec RTL immediately, in parallel with board work.
5. Download **AN 974** and the **Package/Pinout/PCB Design User Guide** before any schematic
   capture begins.
