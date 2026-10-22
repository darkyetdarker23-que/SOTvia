# -*- coding: utf-8 -*-
"""Loopback-only TCP relay for the ChatGPT durable WebSocket.

The relay does not decrypt TLS. It forwards 127.0.0.1:443 through the
recipient's local SOT SOCKS5 listener and asks SOCKS5 to resolve the target
hostname remotely.
"""

import argparse
import logging
from logging.handlers import RotatingFileHandler
import os
import socket
import struct
import sys
import threading


BUFFER = 64 * 1024
LINGER_SECONDS = 60


def configure_logging(log_file):
    logger = logging.getLogger("forwarder")
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"
    )
    if log_file:
        directory = os.path.dirname(os.path.abspath(log_file))
        os.makedirs(directory, exist_ok=True)
        handler = RotatingFileHandler(
            log_file, maxBytes=1024 * 1024, backupCount=3, encoding="utf-8"
        )
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    if sys.stdout is not None:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(formatter)
        logger.addHandler(handler)
    return logger


def recv_exact(sock, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise EOFError("SOCKS5 reply ended %d byte(s) early" % remaining)
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def socks5_connect(socks_host, socks_port, target_host, target_port, timeout):
    upstream = socket.create_connection((socks_host, socks_port), timeout=timeout)
    try:
        upstream.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        upstream.sendall(b"\x05\x01\x00")
        greeting = recv_exact(upstream, 2)
        if greeting != b"\x05\x00":
            raise OSError("SOCKS5 greeting failed: %r" % (greeting,))

        host_bytes = target_host.encode("idna")
        if len(host_bytes) > 255:
            raise ValueError("SOCKS5 target hostname is too long")
        request = (
            b"\x05\x01\x00\x03"
            + bytes([len(host_bytes)])
            + host_bytes
            + struct.pack(">H", target_port)
        )
        upstream.sendall(request)

        header = recv_exact(upstream, 4)
        if header[0] != 5 or header[2] != 0:
            raise OSError("Invalid SOCKS5 reply header: %r" % (header,))
        if header[1] != 0:
            raise OSError("SOCKS5 CONNECT failed with REP=%d" % header[1])

        address_type = header[3]
        if address_type == 1:
            recv_exact(upstream, 4 + 2)
        elif address_type == 3:
            recv_exact(upstream, recv_exact(upstream, 1)[0] + 2)
        elif address_type == 4:
            recv_exact(upstream, 16 + 2)
        else:
            raise OSError("Unknown SOCKS5 address type: %d" % address_type)

        # The timeout is only for the SOCKS5 handshake. A durable WebSocket
        # must not be torn down merely because no payload arrived for 15 s.
        upstream.settimeout(None)
        return upstream
    except Exception:
        upstream.close()
        raise


class BidirectionalPipe:
    """Copy both TCP directions with half-close semantics."""

    def __init__(self, first, second, logger, connection_id):
        self.first = first
        self.second = second
        self.logger = logger
        self.connection_id = connection_id
        self.lock = threading.Lock()
        self.remaining = 2
        self.closed = False
        self.watchdog = None

    def copy(self, source, destination, direction):
        try:
            while True:
                data = source.recv(BUFFER)
                if not data:
                    break
                destination.sendall(data)
        except OSError as error:
            self.logger.info(
                "connection=%s direction=%s ended: %s",
                self.connection_id,
                direction,
                error,
            )
        finally:
            self.finish_direction(destination)

    def finish_direction(self, destination):
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass

        close_now = False
        with self.lock:
            if self.closed:
                return
            self.remaining -= 1
            if self.remaining == 0:
                close_now = True
            elif self.watchdog is None:
                self.watchdog = threading.Timer(LINGER_SECONDS, self.close_all)
                self.watchdog.daemon = True
                self.watchdog.start()
        if close_now:
            self.close_all()

    def close_all(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
        for current in (self.first, self.second):
            try:
                current.close()
            except OSError:
                pass
        self.logger.info("connection=%s closed", self.connection_id)


def handle_client(client, address, args, logger, connection_id):
    try:
        client.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        upstream = socks5_connect(
            args.socks_host,
            args.socks_port,
            args.target_host,
            args.target_port,
            args.connect_timeout,
        )
    except Exception as error:
        logger.warning("connection=%s upstream failed: %s", connection_id, error)
        client.close()
        return

    logger.info(
        "connection=%s client=%s:%s target=%s:%s established",
        connection_id,
        address[0],
        address[1],
        args.target_host,
        args.target_port,
    )
    pipe = BidirectionalPipe(client, upstream, logger, connection_id)
    thread = threading.Thread(
        target=pipe.copy,
        args=(client, upstream, "client-to-upstream"),
        daemon=True,
    )
    thread.start()
    pipe.copy(upstream, client, "upstream-to-client")


def parse_args():
    parser = argparse.ArgumentParser(description="ChatGPT durable WebSocket relay")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=443)
    parser.add_argument("--socks-host", default="127.0.0.1")
    parser.add_argument("--socks-port", type=int, default=1081)
    parser.add_argument("--target-host", default="codex-cloud-backend.chatgpt.com")
    parser.add_argument("--target-port", type=int, default=443)
    parser.add_argument("--connect-timeout", type=float, default=15.0)
    parser.add_argument("--log-file")
    return parser.parse_args()


def main():
    args = parse_args()
    logger = configure_logging(args.log_file)
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        server.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.listen_host, args.listen_port))
    server.listen(32)
    logger.info(
        "listening %s:%d -> socks5 %s:%d -> %s:%d",
        args.listen_host,
        args.listen_port,
        args.socks_host,
        args.socks_port,
        args.target_host,
        args.target_port,
    )

    next_connection_id = 1
    while True:
        client, address = server.accept()
        connection_id = next_connection_id
        next_connection_id += 1
        thread = threading.Thread(
            target=handle_client,
            args=(client, address, args, logger, connection_id),
            daemon=True,
        )
        thread.start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        logging.getLogger("forwarder").exception("fatal error: %s", exc)
        raise

