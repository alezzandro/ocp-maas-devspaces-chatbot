#!/usr/bin/env python3
"""Platform agent and MCP policy proxy for the optional agent-identity lab.

The proxy is the enforcement point that can see the MCP JSON-RPC body.
The gateway AuthPolicy checks the same SPIFFE subject and tool header.
A caller cannot swap the header and the tool name: both must agree.
"""

import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ALLOWED_TOOLS = ("pods_list", "pods_get", "events_list", "namespaces_list")
SESSION_HEADER = "mcp-initialize"
NAMESPACE = "agent-governance"


def trust_domain():
    return os.environ.get("TRUST_DOMAIN", "example.com")


def spiffe_id(service_account):
    return f"spiffe://{trust_domain()}/ns/{NAMESPACE}/sa/{service_account}"


def platform_id():
    return spiffe_id("platform-agent")


def decide(subject, header, method, tool_name):
    """Return (allowed, reason) for one MCP request."""
    header = header or ""
    method = method or ""
    tool_name = tool_name or ""
    if subject != platform_id():
        return False, "SPIFFE ID is not the platform agent"
    if method in ("initialize", "notifications/initialized", "ping"):
        if header not in ("", SESSION_HEADER):
            return False, "session call must not claim a workload tool"
        return True, "session"
    if method != "tools/call":
        return False, "method is not a tool call"
    if tool_name not in ALLOWED_TOOLS:
        return False, "tool is outside the platform-agent health intent"
    if header != tool_name:
        return False, "tool header does not match the JSON-RPC tool name"
    return True, "allowed"


def parse_mcp(body):
    try:
        payload = json.loads(body.decode("utf-8") if isinstance(body, bytes) else body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return "", ""
    if not isinstance(payload, dict):
        return "", ""
    method = str(payload.get("method") or "")
    params = payload.get("params") or {}
    tool_name = ""
    if isinstance(params, dict):
        tool_name = str(params.get("name") or "")
    return method, tool_name


def _ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


_jwks_cache = {"body": b"", "at": 0.0}


def public_jwks():
    """Republish the SPIRE key set over cluster HTTP.

    Authorino in this lab has SSL_CERT_FILE pointed at a missing service-CA
    bundle, so an HTTPS jwksUrl fails closed as HTTP 500. The proxy fetches
    the keys with verification disabled and serves them to AuthPolicy.
    """
    now = time.time()
    if _jwks_cache["body"] and now - _jwks_cache["at"] < 30:
        return _jwks_cache["body"]
    import requests

    response = requests.get(os.environ["OIDC_JWKS_URL"], timeout=5, verify=False)
    response.raise_for_status()
    _jwks_cache["body"] = response.content
    _jwks_cache["at"] = now
    return response.content


def verify_jwt(token):
    import jwt
    from jwt import PyJWKClient

    jwks_url = os.environ["OIDC_JWKS_URL"]
    issuer = os.environ["JWT_ISSUER"]
    audience = os.environ.get("JWT_AUDIENCE", "mcp-gateway")
    client = PyJWKClient(jwks_url, ssl_context=_ssl_context())
    key = client.get_signing_key_from_jwt(token)
    return jwt.decode(
        token,
        key.key,
        algorithms=["RS256", "ES256", "ES384"],
        audience=audience,
        issuer=issuer,
    )


def fetch_jwt():
    import logging

    logging.getLogger("grpc").setLevel(logging.ERROR)
    from spiffe import JwtSource

    audience = {os.environ.get("JWT_AUDIENCE", "mcp-gateway")}
    with JwtSource() as source:
        if hasattr(source, "fetch_svid"):
            svid = source.fetch_svid(audience=audience)
        else:
            svid = source.fetch_token_svid(audience=audience)
        return svid.token


def trace(event, detail):
    record = {
        "experiment": "agent-governance-traces",
        "event": event,
        "detail": detail,
    }
    print(json.dumps(record), flush=True)
    tracking = os.environ.get("MLFLOW_TRACKING_URI", "").rstrip("/")
    if not tracking:
        return
    try:
        import requests

        requests.post(
            f"{tracking}/api/2.0/mlflow/experiments/create",
            json={"name": "agent-governance-traces"},
            timeout=5,
            verify=False,
        )
        created = requests.post(
            f"{tracking}/api/2.0/mlflow/runs/create",
            json={"experiment_id": "0", "run_name": event},
            timeout=5,
            verify=False,
        )
        if created.ok:
            run_id = created.json().get("run", {}).get("info", {}).get("run_id")
            if run_id:
                requests.post(
                    f"{tracking}/api/2.0/mlflow/runs/log-metric",
                    json={"run_id": run_id, "key": "allowed", "value": 1 if detail.get("allowed") else 0},
                    timeout=5,
                    verify=False,
                )
    except Exception as exc:
        print(f"mlflow trace skipped: {exc}", flush=True)


def upstream_mcp():
    return os.environ.get(
        "UPSTREAM_MCP_URL",
        "http://openshift-mcp-server.models-as-a-service.svc.cluster.local:8080/mcp",
    )


def forward(method, path, body, in_headers):
    import requests

    headers = {"Content-Type": in_headers.get("Content-Type", "application/json")}
    for name in ("Mcp-Session-Id", "mcp-session-id"):
        if in_headers.get(name):
            headers["Mcp-Session-Id"] = in_headers[name]
    response = requests.post(
        upstream_mcp(),
        data=body,
        headers=headers,
        timeout=60,
    )
    return response.status_code, response.headers, response.content


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"proxy {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code, payload, content_type="application/json"):
        data = payload if isinstance(payload, bytes) else payload.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/healthz"):
            self._send(200, b'{"status":"ok"}')
            return
        if path == "/keys":
            try:
                self._send(200, public_jwks())
            except Exception as exc:
                self._send(502, json.dumps({"error": "jwks unavailable", "detail": str(exc)}))
            return
        self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            trace("deny", {"allowed": False, "reason": "missing bearer token"})
            self._send(401, b'{"error":"SPIFFE JWT required"}')
            return
        token = auth.split(" ", 1)[1].strip()
        try:
            claims = verify_jwt(token)
        except Exception as exc:
            trace("deny", {"allowed": False, "reason": f"jwt: {exc}"})
            self._send(401, json.dumps({"error": "invalid SPIFFE JWT", "detail": str(exc)}))
            return
        subject = str(claims.get("sub") or "")
        header = self.headers.get("X-MCP-Toolname", "")
        method, tool_name = parse_mcp(body)
        allowed, reason = decide(subject, header, method, tool_name)
        trace(
            "allow" if allowed else "deny",
            {
                "allowed": allowed,
                "reason": reason,
                "sub": subject,
                "header": header,
                "method": method,
                "tool": tool_name,
            },
        )
        if not allowed:
            self._send(403, json.dumps({"error": reason, "tool": tool_name, "sub": subject}))
            return
        try:
            status, headers, content = forward(method, self.path, body, self.headers)
        except Exception as exc:
            self._send(502, json.dumps({"error": "upstream MCP failed", "detail": str(exc)}))
            return
        self.send_response(status)
        for name in ("Content-Type", "Mcp-Session-Id"):
            value = headers.get(name)
            if value:
                self.send_header(name, value)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


def serve():
    port = int(os.environ.get("PROXY_PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), ProxyHandler)
    print(f"mcp policy proxy listening on {port}", flush=True)
    server.serve_forever()


def call_tool(tool_name):
    import requests

    token = fetch_jwt()
    proxy = os.environ.get(
        "PROXY_URL",
        "http://mcp-policy-proxy.agent-governance.svc.cluster.local:8080/mcp",
    )
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    session = requests.post(
        proxy,
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "platform-agent", "version": "0.1"},
            },
        },
        headers={**headers, "X-MCP-Toolname": SESSION_HEADER},
        timeout=60,
    )
    if session.status_code != 200:
        print(session.status_code)
        print(session.text[:2000])
        return session.status_code, session.text
    session_id = session.headers.get("Mcp-Session-Id") or session.headers.get("mcp-session-id")
    call_headers = {**headers, "X-MCP-Toolname": tool_name}
    if session_id:
        call_headers["Mcp-Session-Id"] = session_id
        requests.post(
            proxy,
            json={"jsonrpc": "2.0", "method": "notifications/initialized"},
            headers={**headers, "X-MCP-Toolname": SESSION_HEADER, "Mcp-Session-Id": session_id},
            timeout=60,
        )
    response = requests.post(
        proxy,
        json={
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": {}},
        },
        headers=call_headers,
        timeout=90,
    )
    print(response.status_code)
    print(response.text[:2000])
    return response.status_code, response.text


def complete_chat():
    import requests

    url = os.environ.get(
        "VLLM_URL",
        "https://qwen3-8b-fp8-kserve-workload-svc.models-as-a-service.svc.cluster.local:8000/v1/chat/completions",
    )
    model = os.environ.get("VLLM_MODEL", "qwen3-8b-fp8")
    response = requests.post(
        url,
        json={
            "model": model,
            "messages": [{"role": "user", "content": "Reply with the single word ready."}],
            "max_tokens": 16,
            "temperature": 0,
        },
        timeout=120,
        verify=False,
    )
    return response.status_code, response.text


def ask_model():
    code, text = complete_chat()
    print(code)
    print(text[:2000])
    return code


def self_test():
    os.environ["TRUST_DOMAIN"] = "demo.example"
    platform = platform_id()
    untrusted = spiffe_id("untrusted-agent")
    checks = [
        (True, decide(platform, "pods_list", "tools/call", "pods_list")),
        (True, decide(platform, "pods_get", "tools/call", "pods_get")),
        (True, decide(platform, "events_list", "tools/call", "events_list")),
        (True, decide(platform, "namespaces_list", "tools/call", "namespaces_list")),
        (False, decide(platform, "pods_log", "tools/call", "pods_log")),
        (False, decide(platform, "resources_get", "tools/call", "resources_get")),
        (False, decide(platform, "configuration_view", "tools/call", "configuration_view")),
        (False, decide(platform, "pods_list", "tools/call", "pods_log")),
        (False, decide(untrusted, "pods_list", "tools/call", "pods_list")),
        (True, decide(platform, SESSION_HEADER, "initialize", "")),
        (False, decide(untrusted, SESSION_HEADER, "initialize", "")),
    ]
    failed = 0
    for expected, (allowed, reason) in checks:
        if allowed != expected:
            failed += 1
            print(f"FAIL expected allowed={expected} got {allowed} ({reason})")
    if failed:
        print(f"self-test failed: {failed}")
        return 1
    print("self-test passed")
    return 0


DEMO_ACTIONS = (
    "identity",
    "pods_list",
    "namespaces_list",
    "events_list",
    "pods_log",
    "resources_get",
    "configuration_view",
    "ask",
)


def identity_document():
    import jwt

    token = fetch_jwt()
    claims = jwt.decode(token, options={"verify_signature": False, "verify_aud": False})
    return {
        "sub": claims.get("sub"),
        "aud": claims.get("aud"),
        "iss": claims.get("iss"),
        "expires_at": claims.get("exp"),
    }


def summarize_body(body):
    text = body or ""
    for line in text.splitlines():
        if line.startswith("data:"):
            text = line.split(":", 1)[1].strip()
            break
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return text[:1500]
    if isinstance(payload, dict) and isinstance(payload.get("error"), str):
        return payload["error"][:1500]
    result = payload.get("result") if isinstance(payload, dict) else None
    content = result.get("content") if isinstance(result, dict) else None
    if isinstance(content, list) and content:
        piece = content[0].get("text") if isinstance(content[0], dict) else ""
        if piece:
            return str(piece)[:1500]
    if isinstance(payload, dict):
        choices = payload.get("choices")
        if isinstance(choices, list) and choices:
            message = choices[0].get("message") if isinstance(choices[0], dict) else None
            if isinstance(message, dict) and message.get("content"):
                return str(message["content"])[:1500]
    return text[:1500]


def perform(action):
    identity = identity_document()
    if action == "identity":
        return {
            "allowed": True,
            "status": 200,
            "identity": identity,
            "summary": "This workload holds a short-lived SPIFFE JWT. The subject is the non-human identity.",
        }
    if action == "ask":
        code, text = complete_chat()
        return {
            "allowed": code == 200,
            "status": code,
            "identity": identity,
            "summary": summarize_body(text) if code == 200 else f"Model call returned HTTP {code}.",
        }
    result = call_tool(action)
    if isinstance(result, tuple):
        code, body = result
    else:
        code, body = result, ""
    allowed = code == 200 and "is invalid" not in (body or "")
    return {
        "allowed": allowed,
        "status": code,
        "identity": identity,
        "summary": summarize_body(body) or f"HTTP {code}",
    }


def write_response(handler, code, payload):
    if isinstance(payload, bytes):
        data = payload
        content_type = "application/json"
    elif isinstance(payload, str):
        data = payload.encode("utf-8")
        content_type = "text/html; charset=utf-8" if payload.lstrip().startswith("<") else "application/json"
    else:
        data = json.dumps(payload).encode("utf-8")
        content_type = "application/json"
    handler.send_response(code)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class AgentHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"agent {self.address_string()} {fmt % args}", flush=True)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            write_response(self, 200, {"status": "ok"})
            return
        if path == "/identity":
            try:
                write_response(self, 200, identity_document())
            except Exception as exc:
                write_response(self, 503, {"error": str(exc)})
            return
        write_response(self, 404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/act":
            write_response(self, 404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            requested = json.loads(raw.decode("utf-8")).get("action") or "identity"
        except json.JSONDecodeError:
            write_response(self, 400, {"error": "expected JSON"})
            return
        if requested not in DEMO_ACTIONS:
            write_response(self, 400, {"error": "unknown action"})
            return
        try:
            write_response(self, 200, perform(requested))
        except Exception as exc:
            write_response(self, 503, {"error": str(exc)})


def serve_agent():
    port = int(os.environ.get("AGENT_PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), AgentHandler)
    print(f"agent api listening on {port}", flush=True)
    server.serve_forever()


CONSOLE_AGENTS = {
    "platform-agent": "http://platform-agent.agent-governance.svc.cluster.local:8080",
    "untrusted-agent": "http://untrusted-agent.agent-governance.svc.cluster.local:8080",
}


class ConsoleHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"console {self.address_string()} {fmt % args}", flush=True)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            write_response(self, 200, {"status": "ok"})
            return
        if path in ("/", "/index.html"):
            page = os.path.join(os.path.dirname(__file__), "console.html")
            with open(page, encoding="utf-8") as handle:
                write_response(self, 200, handle.read())
            return
        write_response(self, 404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path != "/api/act":
            write_response(self, 404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            write_response(self, 400, {"error": "expected JSON"})
            return
        agent = str(payload.get("agent") or "")
        action = str(payload.get("action") or "")
        base = CONSOLE_AGENTS.get(agent)
        if base is None or action not in DEMO_ACTIONS:
            write_response(self, 400, {"error": "unknown agent or action"})
            return
        import requests

        try:
            upstream = requests.post(f"{base}/act", json={"action": action}, timeout=120)
        except Exception as exc:
            write_response(self, 502, {"error": f"{agent} unreachable", "detail": str(exc)})
            return
        try:
            body = upstream.json()
        except Exception:
            body = {"error": upstream.text[:500], "status": upstream.status_code}
        write_response(self, 200 if upstream.ok else upstream.status_code, body)


def serve_console():
    port = int(os.environ.get("CONSOLE_PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), ConsoleHandler)
    print(f"agent console listening on {port}", flush=True)
    server.serve_forever()


def main(argv):
    command = argv[1] if len(argv) > 1 else "serve"
    if command == "serve":
        serve()
        return 0
    if command == "agent":
        serve_agent()
        return 0
    if command == "console":
        serve_console()
        return 0
    if command == "self-test":
        return self_test()
    if command == "token":
        print(fetch_jwt())
        return 0
    if command == "call":
        tool = argv[2] if len(argv) > 2 else "pods_list"
        result = call_tool(tool)
        if isinstance(result, tuple):
            code, body = result
        else:
            code, body = result, ""
        expect = argv[3] if len(argv) > 3 else ""
        if expect and str(code) != expect:
            return 1
        if expect == "200" and "is invalid" in body:
            return 1
        if expect:
            return 0
        return 0 if code < 500 else 1
    if command == "ask-model":
        code = ask_model()
        return 0 if code == 200 else 1
    print(f"unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
