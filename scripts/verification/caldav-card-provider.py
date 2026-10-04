#!/usr/bin/env python3
"""Loopback-only Chat Completions fixture; actual MCP calls stay in MCPHost."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body["messages"][-1]["role"] == "tool":
            delta = {"role": "assistant", "content": "Synthetic card fetched."}
            finish = "stop"
        else:
            name = next(t["function"]["name"] for t in body["tools"]
                        if "list" in t["function"]["name"] and "todos" in t["function"]["name"])
            delta = {"role": "assistant", "tool_calls": [{"index": 0,
                     "id": "verify0016", "type": "function", "function": {
                         "name": name, "arguments": json.dumps({
                             "calendarId": "functional-verification-0016"})}}]}
            finish = "tool_calls"
        chunk = {"id": "verification", "object": "chat.completion.chunk",
                 "created": 0, "model": "verification", "choices": [{
                     "index": 0, "delta": delta, "finish_reason": finish}]}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())

    def log_message(self, *args):
        # Requests can include normal host tool schemas; no request/credential logging.
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 18464), Handler).serve_forever()
