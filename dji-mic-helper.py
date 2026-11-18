#!/usr/bin/env python3
"""DJI Mic Mini receiver bridge for the Omarchy bar widget.

Finds the receiver, claims its vendor interface through usbfs, decodes the
status stream (v2 firmware) and prints the state as one JSON object per line.
Setting changes arrive on stdin, one per line:

    set <name> <0|1>
    set voiceTone <unit> <normal|rich|bright>

Wire format: https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md
Port of https://github.com/pavlohuk/DJIMicBar (Protocol.swift, USBReader.swift).
"""

import ctypes
import errno
import fcntl
import glob
import json
import os
import select
import struct
import sys
import time

VENDOR_ID = "2ca3"
PRODUCT_ID = "4011"
INTERFACE = 6
BULK_IN = 0x86
BULK_OUT = 0x06

USBDEVFS_BULK = 0xC0185502              # _IOWR('U', 2, struct usbdevfs_bulktransfer)
USBDEVFS_CLAIMINTERFACE = 0x8004550F    # _IOR('U', 15, unsigned int)
USBDEVFS_RELEASEINTERFACE = 0x80045510  # _IOR('U', 16, unsigned int)

LEVEL_INTERVAL = 0.08   # cap level-only updates at ~12 per second


# ---------- CRC-16 (reflected 0x8408), v2 seed ----------

def _crc_table():
    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (c >> 1) ^ 0x8408 if c & 1 else c >> 1
        table.append(c)
    return table


CRC_TABLE = _crc_table()


def crc_v2(data):
    crc = 0x3692
    for b in data:
        crc = (crc >> 8) ^ CRC_TABLE[(crc ^ b) & 0xFF]
    return crc


# ---------- Decoder ----------

def ascii_text(data):
    end = data.find(0)
    if end >= 0:
        data = data[:end]
    return data.decode("utf-8", "replace").strip()[:64]


class Decoder:
    def __init__(self):
        self.buffer = bytearray()
        self.identities = {}    # 0 = receiver, 1/2 = transmitters
        self.levels = {}
        self.has_status = False
        self.legacy = False
        self.rx = {}
        self.tx = []

    def feed(self, data):
        self.buffer += data
        while True:
            frame = self._take_frame()
            if frame is None:
                break
            self._decode(frame)
        if len(self.buffer) > 4096:
            del self.buffer[:len(self.buffer) - 1024]

    def _take_frame(self):
        """Pull the next complete frame: 0x55, length, 0x04, ..., CRC-16."""
        buf = self.buffer
        i = 0
        while i < len(buf):
            if buf[i] != 0x55:
                i += 1
                continue
            if i + 2 >= len(buf):
                break
            length = buf[i + 1]
            if buf[i + 2] != 0x04 or length < 13:
                i += 1
                continue
            if i + length > len(buf):
                break
            frame = bytes(buf[i:i + length])
            if len(frame) >= 56 and frame[9:12] == b"\x5b\x03\x00":
                self.legacy = True      # v1 heartbeat, not decoded
            elif crc_v2(frame) == 0:
                del buf[:i + length]
                return frame
            i += 1
        del buf[:min(i, len(buf))]
        return None

    def _decode(self, f):
        # Status, identity and level pushes all carry `5b 03 03` at offset 9.
        if len(f) < 16 or f[9:12] != b"\x5b\x03\x03":
            return
        if self._decode_records(f):
            return
        self._decode_status(f)

    def _decode_records(self, f):
        """Identity and level pushes: [tag][unit][3 reserved][len][data] from offset 14."""
        end = len(f) - 2
        i = 14
        parsed = []
        while i < end:
            if i + 6 > end or f[i] not in (0x01, 0x04, 0x05, 0x06):
                return False
            data_end = i + 6 + f[i + 5]
            if data_end > end:
                return False
            parsed.append((f[i], f[i + 1], f[i + 6:data_end]))
            i = data_end
        if not parsed:
            return False
        for tag, unit, d in parsed:
            if unit > 2:
                continue
            if tag == 0x01 and len(d) > 4:
                ident = self.identities.setdefault(unit, {})
                ident["firmware"] = "%02d.%02d.%02d.%02d" % (d[3], d[2], d[1], d[0])
                ident["serial"] = ascii_text(d[4:])
            elif tag == 0x06:
                self.identities.setdefault(unit, {})["name"] = ascii_text(d)
            elif tag == 0x05 and len(d) == 1 and unit >= 1:
                self.levels[unit] = d[0]
        return True

    def _decode_status(self, f):
        """Status push: 52-byte header, one 32-byte slot per transmitter, CRC."""
        body = len(f) - 54
        if body < 0 or body % 32:
            return
        self.has_status = True
        self.rx = {
            "ncStrong": bool(f[20] & 0x08),
            "ncEnabled": bool(f[20] & 0x20),
            "stereo": bool(f[21] & 0x04),
            "clipLimiter": bool(f[48] & 0x10),
        }
        tx = []
        for n in range(min(body // 32, 2)):
            o = 52 + 32 * n
            unit = f[o + 1]
            if f[o] != 0x02 or unit not in (1, 2):
                continue
            tone = "bright" if f[o + 9] & 0x80 else ("rich" if f[o + 9] & 0x40 else "normal")
            tx.append({
                "unit": unit,
                "battery": (f[o + 7] >> 2) & 0x07,   # 1 = full ... 7 = critical, 0 = unknown
                "charging": bool(f[o + 7] & 0x02),
                "ledsOn": not f[o + 6] & 0x02,
                "autoOff": bool(f[o + 6] & 0x10),
                "ncButton": bool(f[o + 6] & 0x80),
                "lowCut": bool(f[o + 9] & 0x20),
                "voiceTone": tone,
            })
        tx.sort(key=lambda t: t["unit"])
        # Forget what we learned about a transmitter once it disconnects.
        present = {t["unit"] for t in tx}
        for unit in (1, 2):
            if unit not in present:
                self.identities.pop(unit, None)
                self.levels.pop(unit, None)
        self.tx = tx

    def state(self):
        tx = []
        for t in self.tx:
            ident = self.identities.get(t["unit"], {})
            tx.append(dict(t, level=self.levels.get(t["unit"], 0),
                           firmware=ident.get("firmware", ""),
                           serial=ident.get("serial", ""),
                           name=ident.get("name", "")))
        rx_ident = self.identities.get(0, {})
        return {
            "present": True,
            "error": "",
            "hasStatus": self.has_status,
            "legacy": self.legacy,
            "rx": dict(self.rx, firmware=rx_ident.get("firmware", ""),
                       serial=rx_ident.get("serial", "")),
            "tx": tx,
        }


# ---------- Commands (v2 firmware) ----------

RECEIVER = 0x0000
ALL_TX = 0xFFFF
TONES = {"normal": 0, "rich": 1, "bright": 2}


def wire(args):
    """Map `set` arguments to (target, command, value), or None."""
    if len(args) == 3 and args[0] == "voiceTone":
        if args[1] in ("1", "2") and args[2] in TONES:
            return int(args[1]), 0x0029, TONES[args[2]]
        return None
    if len(args) != 2 or args[1] not in ("0", "1"):
        return None
    on = args[1] == "1"
    table = {
        "lowCut": (ALL_TX, 0x0003, int(on)),
        "micLEDs": (ALL_TX, 0x000A, 0x00 if on else 0x02),   # inverted
        "txAutoOff": (ALL_TX, 0x0010, int(on)),
        "ncButton": (ALL_TX, 0x000F, int(on)),
        "stereo": (RECEIVER, 0x0008, 0x02 if on else 0x00),
        "clipLimiter": (RECEIVER, 0x001E, int(on)),
    }
    return table.get(args[0])


def build_command(seq, target, command, value):
    """22-byte target-addressed command frame, CRC included."""
    p = bytearray([
        0x55, 22, 0x04, 0xFC,                    # start, length, version, header CRC-8
        0x02, 0x5A,                              # audio subsystem, attribute flags
        seq & 0xFF, seq >> 8,
        0x40, 0x5B, 0x01, 0x02,                  # ACK requested, target-addressed sub-type
        target & 0xFF, target >> 8, 0x00, 0x00,
        command & 0xFF, command >> 8,
        0x01, value,
    ])
    crc = crc_v2(p)
    p += bytes([crc & 0xFF, crc >> 8])
    return bytes(p)


# ---------- USB transport (usbfs) ----------

def find_device():
    """Return the /dev/bus/usb node of the receiver, or None."""
    for path in glob.glob("/sys/bus/usb/devices/*/idVendor"):
        base = os.path.dirname(path)
        try:
            with open(path) as fh:
                if fh.read().strip() != VENDOR_ID:
                    continue
            with open(base + "/idProduct") as fh:
                if fh.read().strip() != PRODUCT_ID:
                    continue
            with open(base + "/busnum") as fh:
                bus = int(fh.read())
            with open(base + "/devnum") as fh:
                dev = int(fh.read())
        except (OSError, ValueError):
            continue
        return "/dev/bus/usb/%03d/%03d" % (bus, dev)
    return None


class Device:
    def __init__(self, node):
        self.fd = os.open(node, os.O_RDWR)
        try:
            fcntl.ioctl(self.fd, USBDEVFS_CLAIMINTERFACE, struct.pack("I", INTERFACE))
        except OSError:
            os.close(self.fd)
            raise
        self.buf = ctypes.create_string_buffer(512)

    def _bulk(self, endpoint, length, timeout_ms):
        req = bytearray(struct.pack("IIIP", endpoint, length, timeout_ms,
                                    ctypes.addressof(self.buf)))
        return fcntl.ioctl(self.fd, USBDEVFS_BULK, req)

    def read(self, timeout_ms):
        try:
            got = self._bulk(BULK_IN, len(self.buf), timeout_ms)
        except OSError as e:
            if e.errno == errno.ETIMEDOUT:
                return b""
            raise
        return self.buf.raw[:got]

    def write(self, data):
        ctypes.memmove(self.buf, data, len(data))
        self._bulk(BULK_OUT, len(data), 1000)

    def close(self):
        try:
            fcntl.ioctl(self.fd, USBDEVFS_RELEASEINTERFACE, struct.pack("I", INTERFACE))
        except OSError:
            pass
        os.close(self.fd)


# ---------- Main loop ----------

class Stdin:
    """Non-blocking line reader; exits the helper when the shell goes away."""

    def __init__(self):
        self.pending = b""

    def lines(self, timeout):
        ready, _, _ = select.select([0], [], [], timeout)
        if not ready:
            return []
        chunk = os.read(0, 4096)
        if not chunk:
            sys.exit(0)
        self.pending += chunk
        *lines, self.pending = self.pending.split(b"\n")
        return [line.decode("utf-8", "replace").split() for line in lines[:16]]


class Publisher:
    def __init__(self):
        self.last = None
        self.last_time = 0.0

    def publish(self, state):
        if state == self.last:
            return
        # A change in input level alone is rate limited; anything else goes out at once.
        now = time.monotonic()
        if self.last is not None and now - self.last_time < LEVEL_INTERVAL \
                and self._without_levels(state) == self._without_levels(self.last):
            return
        self.last = state
        self.last_time = now
        sys.stdout.write(json.dumps(state, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    @staticmethod
    def _without_levels(state):
        return json.dumps(dict(state, tx=[dict(t, level=0) for t in state.get("tx", [])]),
                          sort_keys=True)


def absent(error=""):
    return {"present": error != "", "error": error, "hasStatus": False, "legacy": False,
            "rx": {}, "tx": []}


def session(device, stdin, out):
    decoder = Decoder()
    seq = 1
    failures = 0
    out.publish(decoder.state())
    while True:
        for words in stdin.lines(0):
            if len(words) < 2 or words[0] != "set":
                continue
            target = wire(words[1:])
            if target is None:
                continue
            try:
                device.write(build_command(seq, *target))
            except OSError:
                pass
            seq = (seq + 1) & 0xFFFF
        try:
            data = device.read(250)
        except OSError as e:
            failures += 1
            if e.errno in (errno.ENODEV, errno.ESHUTDOWN, errno.EIO) or failures >= 3:
                return
            continue
        failures = 0
        if data:
            decoder.feed(data)
            out.publish(decoder.state())


def main():
    stdin = Stdin()
    out = Publisher()
    while True:
        node = find_device()
        if node is None:
            out.publish(absent())
            stdin.lines(1.5)
            continue
        try:
            device = Device(node)
        except OSError as e:
            if e.errno == errno.EACCES:
                out.publish(absent("permission"))
            elif e.errno == errno.EBUSY:
                out.publish(absent("busy"))
            elif e.errno in (errno.ENODEV, errno.ENOENT):
                out.publish(absent())
            else:
                out.publish(absent(e.strerror or "error"))
            stdin.lines(2.0)
            continue
        try:
            session(device, stdin, out)
        finally:
            device.close()
        stdin.lines(0.5)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
