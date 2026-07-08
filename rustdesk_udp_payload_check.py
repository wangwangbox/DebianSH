#!/usr/bin/env python3
import os
import socket
import sys
import time


PAYLOAD = bytes.fromhex("32080a06313233343536")
TIMEOUT_SECONDS = 10


def log(message):
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{now} rustdesk_udp_payload_check: {message}", file=sys.stderr, flush=True)


def get_target():
    if len(sys.argv) >= 5:
        host = sys.argv[3]
        port = sys.argv[4]
        source = "argv"
    else:
        host = os.environ.get("HAPROXY_SERVER_ADDR", "")
        port = os.environ.get("HAPROXY_SERVER_PORT", "")
        source = "env"

    if not host or not port:
        raise ValueError("missing HAProxy server address or port")

    return host, int(port), source


def main():
    host, port, source = get_target()
    log(f"start argv={sys.argv!r}")
    log(f"target source={source} host={host} port={port} timeout={TIMEOUT_SECONDS}s payload={PAYLOAD.hex()}")

    log("tcp connect check starting")
    tcp_start = time.monotonic()
    with socket.create_connection((host, port), timeout=TIMEOUT_SECONDS) as conn:
        elapsed_ms = int((time.monotonic() - tcp_start) * 1000)
        local_host, local_port = conn.getsockname()
        log(f"tcp connect ok elapsed_ms={elapsed_ms} local={local_host}:{local_port}")

    log("udp payload check starting")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(TIMEOUT_SECONDS)
        udp_start = time.monotonic()
        sent = sock.sendto(PAYLOAD, (host, port))
        local_host, local_port = sock.getsockname()
        log(f"udp sent bytes={sent} local={local_host}:{local_port} remote={host}:{port} hex={PAYLOAD.hex()}")
        data, addr = sock.recvfrom(4096)
        elapsed_ms = int((time.monotonic() - udp_start) * 1000)
        log(f"udp recv ok elapsed_ms={elapsed_ms} from={addr[0]}:{addr[1]} bytes={len(data)} hex={data.hex()}")

    log("check result=up")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log(f"check result=down error={type(exc).__name__}: {exc}")
        raise SystemExit(1)
