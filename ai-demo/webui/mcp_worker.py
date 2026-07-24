"""
Runs the MCP stdio client + session in a dedicated background thread with its
own asyncio event loop, so Flask's synchronous request handlers can invoke
MCP tools via a simple blocking call (call_tool).
"""

import asyncio
import os
import threading
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from core import ALLOWED_TOOLS, mcp_tool_to_bedrock


class MCPWorker:
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.session: ClientSession | None = None
        self.tools: list = []
        self._ready = threading.Event()
        self._error: Exception | None = None
        self._thread = threading.Thread(target=self._run_loop, daemon=True)

    def start(self, timeout: int = 60):
        self._thread.start()
        if not self._ready.wait(timeout=timeout):
            raise RuntimeError("Timed out waiting for MCP server to start")
        if self._error:
            raise self._error

    def _run_loop(self):
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_until_complete(self._main())
        except Exception as exc:  # noqa: BLE001
            self._error = exc
            self._ready.set()

    async def _main(self):
        mcp_server = os.environ.get(
            "MCP_SERVER_PATH", str(Path.home() / "mcp-confluent" / "dist" / "index.js")
        )
        mcp_config = os.environ.get(
            "MCP_CONFIG_PATH", str(Path(__file__).parent.parent / "hub-mcp-config.yaml")
        )
        ca_cert = os.environ.get("CA_CERT_PATH", "")

        env = {**os.environ}
        if ca_cert:
            env["NODE_EXTRA_CA_CERTS"] = ca_cert

        params = StdioServerParameters(
            command="node", args=[mcp_server, "--config", mcp_config], env=env
        )

        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools_result = await session.list_tools()
                self.session = session
                self.tools = [t for t in tools_result.tools if t.name in ALLOWED_TOOLS]
                self._ready.set()

                self._stop_event = asyncio.Event()
                await self._stop_event.wait()

    def bedrock_tools(self) -> list[dict]:
        return [mcp_tool_to_bedrock(t) for t in self.tools]

    def call_tool(self, name: str, args: dict, timeout: int = 30):
        fut = asyncio.run_coroutine_threadsafe(self.session.call_tool(name, args), self.loop)
        return fut.result(timeout=timeout)
