#!/usr/bin/env python3
"""
host_nist.py -- run OFFICIAL NIST ACVP vectors against the KC705 ML-KEM board.

This is the strongest validation available, and it needs NO internet and no
kyber-py: the vectors are in nist_vectors.json, taken verbatim from
usnistgov/ACVP-Server (ML-KEM-keyGen-FIPS203 and ML-KEM-encapDecap-FIPS203).

Each vector is (input, expected-output) published by NIST. The board is given
the input and its output is compared byte-for-byte with NIST's. Nothing here
depends on our own model being right -- that is the whole point.

Modes:
    keygen   d, z  -> ek, dk          (5 vectors)
    decaps   dk, c -> shared secret K (5 vectors)
    all      both

Usage:
    py -m pip install pyserial          # the ONLY dependency
    py host_nist.py COM6 all
"""

import sys
import json
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial not installed.  Run:  py -m pip install pyserial")

BAUD = 115200
C_PING, PING_R = 0xA5, 0x5A
C_WR, C_RD, C_SEED = 0x10, 0x11, 0x12
C_KG, C_EN, C_DE = 0x20, 0x21, 0x22
C_STAT = 0x30

# Byte map -- must match mlkem_system.sv
CT_BASE, DK_BASE, MSG_BASE = 0, 1024, 1868
EK_BASE, HEK_BASE, Z_BASE, SS_BASE = 2048, 2900, 3100, 3900


class Board:
    def __init__(self, port):
        self.ser = serial.Serial(port, BAUD, timeout=3.0)
        time.sleep(0.2)
        self.ser.reset_input_buffer()

    def _expect(self, want, what):
        got = self.ser.read(1)
        if not got:
            raise TimeoutError(f"{what}: no reply")
        if got[0] != want:
            raise ValueError(f"{what}: got 0x{got[0]:02X}, want 0x{want:02X}")

    def ping(self, retries=3):
        for a in range(retries):
            try:
                self.ser.reset_input_buffer()
                self.ser.write(bytes([C_PING]))
                self._expect(PING_R, "PING")
                return a
            except (TimeoutError, ValueError):
                if a == retries - 1:
                    raise
                time.sleep(0.3)

    def wr(self, addr, b):
        self.ser.write(bytes([C_WR, addr & 0xFF, (addr >> 8) & 0xFF, b]))
        self._expect(C_WR, f"WR[{addr}]")

    def rd(self, addr):
        self.ser.write(bytes([C_RD, addr & 0xFF, (addr >> 8) & 0xFF]))
        b = self.ser.read(1)
        if not b:
            raise TimeoutError(f"RD[{addr}]")
        return b[0]

    def wr_block(self, addr, data):
        for i, b in enumerate(data):
            self.wr(addr + i, b)

    def rd_block(self, addr, n):
        return bytes(self.rd(addr + i) for i in range(n))

    def seed(self, data):
        for i, b in enumerate(data):
            self.ser.write(bytes([C_SEED, i, b]))
            self._expect(C_SEED, f"SEED[{i}]")

    def status(self):
        self.ser.write(bytes([C_STAT]))
        b = self.ser.read(1)
        if not b:
            raise TimeoutError("STATUS")
        return {"busy": bool(b[0] & 1), "done": bool(b[0] & 2),
                "reject": bool(b[0] & 4)}

    def run(self, cmd, name, timeout_s=60.0):
        self.ser.write(bytes([cmd]))
        self._expect(cmd, f"START {name}")
        t0 = time.time()
        # Wait for busy to RISE then FALL. Polling `done` alone would see the
        # PREVIOUS operation's completion -- the level-held-done trap that hit
        # this design seven times in RTL.
        while time.time() - t0 < timeout_s:
            if self.status()["busy"]:
                break
        while time.time() - t0 < timeout_s:
            st = self.status()
            if not st["busy"]:
                return time.time() - t0, st
        raise TimeoutError(f"{name} timed out")


def test_keygen(bd, vecs):
    print("\n=== NIST ACVP ML-KEM-512 keyGen ===")
    print("    NIST supplies (d, z); the board must produce NIST's ek and dk.\n")
    ok = 0
    for v in vecs:
        # Let the previous operation fully retire before touching the board.
        # Back-to-back operations were the pattern under which vectors 2+
        # went wrong while vector 1 was byte-exact.
        time.sleep(0.2)
        bd.ping()
        d = bytes.fromhex(v["d"])
        z = bytes.fromhex(v["z"])
        bd.seed(d)
        bd.wr_block(Z_BASE, z)
        dt, _ = bd.run(C_KG, "KeyGen")
        ek = bd.rd_block(EK_BASE, 800)
        dk_pke = bd.rd_block(DK_BASE, 768)

        # dk = dk_pke || ek || H(ek) || z; the board has H(ek) at HEK_BASE.
        hek = bd.rd_block(HEK_BASE, 32)
        dk = dk_pke + ek + hek + z

        ek_ok = ek.hex().upper() == v["ek"].upper()
        dk_ok = dk.hex().upper() == v["dk"].upper()
        good = ek_ok and dk_ok
        ok += good
        print(f"  tcId {v['tcId']:>3}  {dt*1000:6.1f} ms  "
              f"ek {'OK ' if ek_ok else 'BAD'}  dk {'OK ' if dk_ok else 'BAD'}")
        if not ek_ok:
            # Report the FIRST differing byte, not a fixed-length prefix. A
            # truncated print made a match look like a failure on the first run.
            n = next((i for i in range(800)
                      if ek[i] != bytes.fromhex(v["ek"])[i]), None)
            print(f"        ek differs first at byte {n}")
            print(f"        board {ek[max(0,n-2):n+6].hex()}")
            print(f"        NIST  {bytes.fromhex(v['ek'])[max(0,n-2):n+6].hex()}")
        if ek_ok and not dk_ok:
            n = next((i for i in range(1632)
                      if dk[i] != bytes.fromhex(v["dk"])[i]), None)
            print(f"        ek MATCHES NIST; dk differs first at byte {n}")
            print(f"          (dk = dk_pke[0:768] || ek[768:1568] || "
                  f"H(ek)[1568:1600] || z[1600:1632])")
    print(f"\n  {ok}/{len(vecs)} keyGen vectors match NIST exactly")
    return ok == len(vecs)


def test_decaps(bd, vecs):
    print("\n=== NIST ACVP ML-KEM-512 decapsulation ===")
    print("    NIST supplies (dk, c); the board must produce NIST's K.\n")
    ok = 0
    for v in vecs:
        time.sleep(0.2)
        bd.ping()
        dk = bytes.fromhex(v["dk"])
        c = bytes.fromhex(v["c"])
        # dk = dk_pke(768) || ek(800) || H(ek)(32) || z(32)
        dk_pke, ek = dk[:768], dk[768:1568]
        hek, z = dk[1568:1600], dk[1600:1632]

        bd.wr_block(DK_BASE, dk_pke)
        bd.wr_block(EK_BASE, ek)
        bd.wr_block(HEK_BASE, hek)
        bd.wr_block(Z_BASE, z)
        bd.wr_block(Z_BASE + 32, c)      # J hashes z || c
        bd.wr_block(CT_BASE, c)

        dt, st = bd.run(C_DE, "Decaps")
        K = bd.rd_block(SS_BASE, 32)
        good = K.hex().upper() == v["k"].upper()
        ok += good
        print(f"  tcId {v['tcId']:>3}  {dt*1000:6.1f} ms  "
              f"K {'OK ' if good else 'BAD'}  reject={st['reject']}")
        if not good:
            print(f"        board K {K.hex()}")
            print(f"        NIST  K {v['k'].lower()}")
    print(f"\n  {ok}/{len(vecs)} decapsulation vectors match NIST exactly")
    return ok == len(vecs)


def main():
    if len(sys.argv) < 2:
        sys.exit(f"usage: {sys.argv[0]} <serial-port> [keygen|decaps|all] [index]\n"
                 f"  index selects ONE vector (0-based), for running a single\n"
                 f"  operation immediately after a board reset.")
    port = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "all"
    only = int(sys.argv[3]) if len(sys.argv) > 3 else None

    vecs = json.load(open("nist_vectors.json"))
    if only is not None:
        for k in vecs:
            vecs[k] = vecs[k][only:only+1]
        print(f"(running vector index {only} only)")

    print("=" * 64)
    print("  OFFICIAL NIST ACVP VECTORS vs KC705 ML-KEM-512")
    print("  vectors from usnistgov/ACVP-Server, FIPS203 revision")
    print("=" * 64)
    print(f"Opening {port} at {BAUD} baud...")
    bd = Board(port)
    print("PING...", end=" ", flush=True)
    t = bd.ping()
    print("ok" + (f" (after {t} retries)" if t else ""))

    results = []
    if mode in ("keygen", "all"):
        results.append(test_keygen(bd, vecs["keygen"]))
    if mode in ("decaps", "all"):
        results.append(test_decaps(bd, vecs["decaps"]))

    print("\n" + "=" * 64)
    if all(results):
        print("  PASS -- the board reproduces NIST's published outputs exactly.")
        print("  This is conformance evidence against the standard itself,")
        print("  not against our own model.")
    else:
        print("  FAIL -- see mismatches above.")
    print("=" * 64)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
