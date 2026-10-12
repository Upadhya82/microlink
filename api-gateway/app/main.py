import httpx
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from app import rate_limit

app = FastAPI(title="MicroLink API Gateway", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SERVICE_MAP = {
    "/auth": "http://user-service:8000",
    "/users": "http://user-service:8000",
    "/shops": "http://shop-service:8000",
    "/recommendations": "http://recommendation-service:8000",
    "/navigation": "http://navigation-service:8000",
    "/orders": "http://delivery-service:8000",
    "/delivery": "http://delivery-service:8000",
    "/crowdsource": "http://crowdsource-service:8000",
    "/admin": "http://admin-service:8000",
    "/ads": "http://admin-service:8000",
    "/notifications": "http://admin-service:8000",
}

# httpx already decodes the body, so these upstream headers no longer match it.
_DROP_RESPONSE_HEADERS = {"content-encoding", "content-length", "transfer-encoding", "connection"}


# Declared before the catch-all proxy route so it is matched first.
@app.get("/health")
def health():
    return {"status": "ok", "service": "api-gateway"}


def _strip_api_prefix(path: str) -> str:
    # The Flutter app calls /api/<service-path>; services themselves have no /api prefix.
    if path == "api" or path.startswith("api/"):
        return path[4:]
    return path


def _resolve_target(path: str) -> str | None:
    full_path = f"/{path}"
    for prefix, host in SERVICE_MAP.items():
        if full_path == prefix or full_path.startswith(prefix + "/"):
            return host
    return None


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"])
async def gateway_proxy(request: Request, path: str):
    path = _strip_api_prefix(path)
    target_host = _resolve_target(path)
    if target_host is None:
        return Response(
            content='{"detail":"Not Found"}', status_code=404, media_type="application/json"
        )

    client = request.client.host if request.client else "unknown"
    retry_after = rate_limit.check(client, request.method, path)
    if retry_after is not None:
        return Response(
            content='{"detail":"Too many attempts. Please wait and try again."}',
            status_code=429,
            media_type="application/json",
            headers={"Retry-After": str(retry_after)},
        )

    url = f"{target_host}/{path}"
    if request.url.query:
        url += f"?{request.url.query}"

    headers = dict(request.headers)
    headers.pop("host", None)
    body = await request.body()

    # 60s because photo/document uploads are slow on a phone connection.
    # follow_redirects: a service's 307 points at an internal Docker hostname the
    # phone cannot reach, so the gateway has to follow it itself.
    async with httpx.AsyncClient(timeout=60.0, follow_redirects=True) as client:
        try:
            res = await client.request(
                method=request.method,
                url=url,
                headers=headers,
                content=body,
            )
        except httpx.RequestError:
            return Response(
                content='{"detail":"Upstream service unavailable"}',
                status_code=503,
                media_type="application/json",
            )

    response_headers = {
        k: v for k, v in res.headers.items() if k.lower() not in _DROP_RESPONSE_HEADERS
    }
    return Response(content=res.content, status_code=res.status_code, headers=response_headers)
