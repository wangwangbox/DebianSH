#!/usr/bin/env python3
"""
DNS proxy that can answer A/AAAA queries by reading encrypted IPs from TXT.

The TXT value is expected to be a hex string. It is decrypted with repeating-key
XOR using --key, decoded as UTF-8/ASCII text, and validated as an IP address.
"""

import argparse
import ipaddress
import os
import random
import socket
import struct
import subprocess
import sys
import time


TYPE_A = 1
TYPE_AAAA = 28
TYPE_TXT = 16
CLASS_IN = 1


class DnsError(Exception):
    pass


def xor_crypt(data, key):
    if not key:
        raise ValueError("key must not be empty")
    key_bytes = key.encode("utf-8")
    return bytes(byte ^ key_bytes[index % len(key_bytes)] for index, byte in enumerate(data))


def encrypt_text(text, key):
    return xor_crypt(text.encode("utf-8"), key).hex()


def decrypt_hex_text(hex_text, key):
    encrypted = bytes.fromhex("".join(hex_text.split()))
    plain = xor_crypt(encrypted, key)
    return plain.decode("utf-8").strip().strip('"').strip()


def validate_ip(value):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError as exc:
        raise DnsError("decrypted TXT is not an IP address: %r" % value) from exc
    return str(ip)


def encode_name(name):
    name = name.rstrip(".")
    if not name:
        return b"\x00"
    chunks = []
    for label in name.split("."):
        raw = label.encode("ascii")
        if len(raw) > 63:
            raise DnsError("DNS label too long: %s" % label)
        chunks.append(bytes([len(raw)]) + raw)
    return b"".join(chunks) + b"\x00"


def decode_name(packet, offset):
    labels = []
    jumped = False
    end_offset = offset
    seen = set()

    while True:
        if offset >= len(packet):
            raise DnsError("truncated DNS name")
        length = packet[offset]

        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(packet):
                raise DnsError("truncated DNS pointer")
            pointer = ((length & 0x3F) << 8) | packet[offset + 1]
            if pointer in seen:
                raise DnsError("DNS compression loop")
            seen.add(pointer)
            if not jumped:
                end_offset = offset + 2
                jumped = True
            offset = pointer
            continue

        if length & 0xC0:
            raise DnsError("unsupported DNS label type")

        offset += 1
        if length == 0:
            if not jumped:
                end_offset = offset
            break
        if offset + length > len(packet):
            raise DnsError("truncated DNS label")
        labels.append(packet[offset:offset + length].decode("ascii").lower())
        offset += length

    return ".".join(labels), end_offset


def parse_query(packet):
    if len(packet) < 12:
        raise DnsError("packet too short")
    txid, flags, qdcount, _, _, _ = struct.unpack("!HHHHHH", packet[:12])
    if qdcount < 1:
        raise DnsError("packet has no question")
    qname, offset = decode_name(packet, 12)
    if offset + 4 > len(packet):
        raise DnsError("truncated question")
    qtype, qclass = struct.unpack("!HH", packet[offset:offset + 4])
    question = packet[12:offset + 4]
    return txid, flags, qname, qtype, qclass, question


def build_query(name, qtype):
    txid = random.randrange(0, 65536)
    header = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    question = encode_name(name) + struct.pack("!HH", qtype, CLASS_IN)
    return txid, header + question


def parse_txt_response(packet, expected_txid):
    if len(packet) < 12:
        raise DnsError("TXT response too short")
    txid, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", packet[:12])
    if txid != expected_txid:
        raise DnsError("TXT response transaction id mismatch")
    rcode = flags & 0x000F
    if rcode != 0:
        raise DnsError("upstream DNS returned rcode %d" % rcode)

    offset = 12
    for _ in range(qdcount):
        _, offset = decode_name(packet, offset)
        offset += 4
        if offset > len(packet):
            raise DnsError("truncated TXT response question")

    values = []
    for _ in range(ancount):
        _, offset = decode_name(packet, offset)
        if offset + 10 > len(packet):
            raise DnsError("truncated TXT answer header")
        rtype, rclass, _, rdlength = struct.unpack("!HHIH", packet[offset:offset + 10])
        offset += 10
        rdata = packet[offset:offset + rdlength]
        offset += rdlength
        if rtype != TYPE_TXT or rclass != CLASS_IN:
            continue

        text_parts = []
        pos = 0
        while pos < len(rdata):
            size = rdata[pos]
            pos += 1
            if pos + size > len(rdata):
                raise DnsError("truncated TXT string")
            text_parts.append(rdata[pos:pos + size].decode("utf-8"))
            pos += size
        values.append("".join(text_parts))

    if not values:
        raise DnsError("TXT record not found")
    return values


def query_txt(name, upstream, timeout):
    txid, packet = build_query(name, TYPE_TXT)
    response = send_udp_dns(packet, upstream, timeout)
    return parse_txt_response(response, txid)


def forward_query(packet, upstream, timeout):
    return send_udp_dns(packet, upstream, timeout)


def send_udp_dns(packet, upstream, timeout):
    host, port = parse_host_port(upstream, 53)
    family = socket.AF_INET
    try:
        if ipaddress.ip_address(host).version == 6:
            family = socket.AF_INET6
    except ValueError:
        pass

    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(packet, (host, port))
        response, _ = sock.recvfrom(4096)
    return response


def parse_host_port(value, default_port):
    value = value.strip()
    if value.startswith("["):
        end = value.find("]")
        if end == -1:
            raise DnsError("invalid bracketed upstream: %s" % value)
        host = value[1:end]
        rest = value[end + 1:]
        if rest.startswith(":"):
            return host, int(rest[1:])
        return host, default_port
    if value.count(":") == 1:
        host, port = value.rsplit(":", 1)
        return host, int(port)
    return value, default_port


def normalize_upstream(host, port=53):
    host = host.strip()
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return "%s:%d" % (host, port)
    if ip.version == 6:
        return "[%s]:%d" % (ip.compressed, port)
    return "%s:%d" % (ip.compressed, port)


def system_upstream_from_resolv_conf(path="/etc/resolv.conf"):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="ascii", errors="ignore") as handle:
        for raw_line in handle:
            line = raw_line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "nameserver":
                return normalize_upstream(parts[1])
    return None


def system_upstream_from_windows_ipconfig():
    try:
        output = subprocess.check_output(["ipconfig", "/all"], stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        return None

    text = output.decode("utf-8", errors="ignore")
    lines = text.splitlines()
    collect_continuation = False
    for line in lines:
        stripped = line.strip()
        if "DNS Servers" in line:
            collect_continuation = True
            value = line.split(":", 1)[1].strip() if ":" in line else ""
            if value:
                return normalize_upstream(value)
            continue
        if collect_continuation:
            if not line.startswith(" ") and not line.startswith("\t"):
                collect_continuation = False
                continue
            if stripped:
                return normalize_upstream(stripped)
    return None


def detect_system_upstream():
    upstream = system_upstream_from_resolv_conf()
    if upstream:
        return upstream, "/etc/resolv.conf"
    upstream = system_upstream_from_windows_ipconfig()
    if upstream:
        return upstream, "ipconfig /all"
    raise DnsError("no system DNS server found; please specify --upstream")


def matches_domain(name, domains):
    name = name.rstrip(".").lower()
    for domain in domains:
        domain = domain.rstrip(".").lower()
        if name == domain or name.endswith("." + domain):
            return True
    return False


class TxtIpResolver:
    def __init__(self, upstream, key, timeout, cache_stale):
        self.upstream = upstream
        self.key = key
        self.timeout = timeout
        self.cache_stale = cache_stale
        self.cache = {}

    def resolve_ip(self, name):
        try:
            values = query_txt(name, self.upstream, self.timeout)
            last_error = None
            for value in values:
                try:
                    ip = validate_ip(decrypt_hex_text(value, self.key))
                    self.cache[name] = (ip, time.time())
                    return ip, "fresh"
                except Exception as exc:
                    last_error = exc
            raise DnsError(str(last_error) if last_error else "no usable TXT value")
        except Exception as exc:
            cached = self.cache.get(name)
            if cached and time.time() - cached[1] <= self.cache_stale:
                return cached[0], "cached after error: %s" % exc
            raise


def build_ip_response(txid, request_flags, question, qtype, qclass, ip, ttl, rcode=0):
    del request_flags
    flags = 0x8180 if rcode == 0 else 0x8180 | rcode
    ancount = 1 if rcode == 0 and ip else 0
    header = struct.pack("!HHHHHH", txid, flags, 1, ancount, 0, 0)
    response = header + question
    if ancount:
        ip_obj = ipaddress.ip_address(ip)
        if qtype == TYPE_A and ip_obj.version == 4:
            rdata = socket.inet_aton(ip)
        elif qtype == TYPE_AAAA and ip_obj.version == 6:
            rdata = ip_obj.packed
        else:
            raise DnsError("IP version does not match query type")
        answer = b"\xC0\x0C"
        answer += struct.pack("!HHIH", qtype, qclass, ttl, len(rdata))
        answer += rdata
        response += answer
    return response


def build_txt_response(txid, request_flags, question, qclass, text, ttl):
    del request_flags
    raw = text.encode("utf-8")
    if len(raw) > 255:
        raise DnsError("TXT response is too long")
    header = struct.pack("!HHHHHH", txid, 0x8180, 1, 1, 0, 0)
    answer = b"\xC0\x0C"
    answer += struct.pack("!HHIH", TYPE_TXT, qclass, ttl, len(raw) + 1)
    answer += bytes([len(raw)]) + raw
    return header + question + answer


def serve(args):
    listen_host, listen_port = parse_host_port(args.listen, 5353)
    if args.upstream:
        upstream = args.upstream
        upstream_source = "command line"
    else:
        upstream, upstream_source = detect_system_upstream()
    domains = [item.strip().rstrip(".").lower() for item in args.domains.split(",") if item.strip()]
    resolver = TxtIpResolver(
        upstream=upstream,
        key=args.key,
        timeout=args.timeout,
        cache_stale=args.cache_stale,
    )

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((listen_host, listen_port))
        print("txt-dns-bridge listening on %s:%d" % (listen_host, listen_port), flush=True)
        print("upstream DNS server: %s (%s)" % (upstream, upstream_source), flush=True)
        print("decrypting TXT for domains: %s" % ", ".join(domains), flush=True)

        while True:
            packet, addr = sock.recvfrom(4096)
            try:
                txid, flags, qname, qtype, qclass, question = parse_query(packet)
                if qclass == CLASS_IN and matches_domain(qname, domains) and qtype in (TYPE_A, TYPE_AAAA, TYPE_TXT):
                    try:
                        ip, source = resolver.resolve_ip(qname)
                        ip_obj = ipaddress.ip_address(ip)
                        if qtype == TYPE_TXT:
                            response = build_txt_response(txid, flags, question, qclass, ip, args.ttl)
                            print("%s TXT -> %s (%s)" % (qname, ip, source), flush=True)
                        elif (qtype == TYPE_A and ip_obj.version == 4) or (qtype == TYPE_AAAA and ip_obj.version == 6):
                            response = build_ip_response(txid, flags, question, qtype, qclass, ip, args.ttl)
                            print("%s -> %s (%s)" % (qname, ip, source), flush=True)
                        else:
                            response = forward_query(packet, upstream, args.timeout)
                            print("%s -> upstream (TXT IP version mismatch)" % qname, flush=True)
                    except Exception as exc:
                        response = forward_query(packet, upstream, args.timeout)
                        print("%s -> upstream (%s)" % (qname, exc), flush=True)
                else:
                    response = forward_query(packet, upstream, args.timeout)
                sock.sendto(response, addr)
            except Exception as exc:
                print("request error from %s: %s" % (addr, exc), file=sys.stderr, flush=True)


def parse_args(argv):
    parser = argparse.ArgumentParser(description="DNS proxy that converts encrypted TXT IP records into A/AAAA answers.")
    parser.add_argument("--listen", default="127.0.0.1:5353", help="UDP listen address, default: 127.0.0.1:5353")
    parser.add_argument("--domains", default="windowsupdate.io", help="comma-separated domain suffixes to decrypt")
    parser.add_argument("--upstream", help="upstream DNS server; default: system DNS from /etc/resolv.conf or Windows ipconfig")
    parser.add_argument("--key", default="windowsupdate", help="repeating XOR key")
    parser.add_argument("--ttl", type=int, default=30, help="TTL for returned A records")
    parser.add_argument("--timeout", type=float, default=2.0, help="upstream TXT query timeout in seconds")
    parser.add_argument("--cache-stale", type=int, default=3600, help="seconds to keep using last good IP after errors")
    parser.add_argument("--encrypt", help="print encrypted hex TXT value for this plaintext IP and exit")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    if args.encrypt:
        print(encrypt_text(validate_ip(args.encrypt), args.key))
        return 0
    serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
