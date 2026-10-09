#!/usr/bin/python3
import asyncio
import sys
from importlib.metadata import version

assert sys.version_info >= (3, 8)
for name, expected in (("aiohttp", "3.10.11"), ("httpx", "0.28.1"),
                       ("httpcore", "1.0.9"), ("grpcio", "1.70.0"),
                       ("packaging", "25.0"), ("setuptools", "75.3.2"),
                       ("importlib-metadata", "8.5.0"), ("zipp", "3.20.2")):
    assert version(name) == expected, (name, version(name))
from aiohttp import web
import grpc
import httpx

assert callable(web.AppKey) and callable(web.Server)
assert callable(httpx.AsyncHTTPTransport)
from packaging.utils import canonicalize_version
import importlib_metadata
assert canonicalize_version("1.0.0", strip_trailing_zero=False) == "1.0.0"
assert hasattr(importlib_metadata, "EntryPoints")

async def check():
    server = grpc.aio.server(options=(("grpc.max_allowed_incoming_connections", 1),))
    await server.stop(0)

asyncio.run(check())
