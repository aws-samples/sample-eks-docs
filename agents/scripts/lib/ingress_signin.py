#!/usr/bin/env python3
"""Sign in at ingress the way a person's browser does, then use the chat UI.

    python3 scripts/lib/ingress_signin.py --host chat.<domain> --idp <idp host or prefix> \
        --user <username> --password-env INGRESS_PASSWORD [--ca ca.pem] [--expect <identity>]

Called by scripts/exercise.sh's `signin` phase; run it from a host that reaches the load balancer (scripts/run-stack.sh),
because ingress is internal and its name resolves only there.

THE PATH A PERSON TAKES, every hop asserted rather than followed:
  1. an unauthenticated request is redirected to the identity provider;
  2. the provider's hosted login page carries a form;
  3. the credentials produce an authorization code, handed back to the load balancer;
  4. the load balancer exchanges it and sets AWSELBAuthSessionCookie;
  5. the chat UI answers 200 and names the identity it VERIFIED from x-amzn-oidc-data -- which is
     where a wrong signer, client or expiry check in apps/common/cluster_auth.py shows up, as a
     401 from uvicorn rather than from the load balancer;
  6. a turn is relayed to an agent and answered.

Standard library only, so it runs on the bastion with nothing to install. The password is read from
an environment variable, never an argument, so it does not appear in a process listing or an SSM
command history. Exit status is 0 only when every hop held.
"""
from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--idp", required=True, help="the provider's host, or a distinctive part of it")
    ap.add_argument("--user", required=True)
    ap.add_argument("--password-env", default="INGRESS_PASSWORD")
    ap.add_argument("--ca", default="", help="a CA bundle for a self-signed ingress certificate")
    ap.add_argument("--expect", default="", help="the identity the UI must report")
    ap.add_argument("--agent", default="research")
    # Turns to run after the relay check, each printed as `REPLY <n>: <the agent's text>`, with
    # --turn-wait seconds before each one (the people phase waits for memory extraction).
    ap.add_argument("--turn", action="append", default=[])
    ap.add_argument("--turn-wait", type=float, default=0)
    a = ap.parse_args()
    password = os.environ.get(a.password_env, "")
    if not password:
        print(f"FAIL: ${a.password_env} is empty")
        return 2

    # BOTH trust stores. Ingress may serve a self-signed certificate, so its CA is added --
    # and the provider's hosted UI is on the public internet, so the system store stays. `cafile=`
    # on create_default_context REPLACES the system store, and the login page then fails to verify.
    ctx = ssl.create_default_context()
    if a.ca:
        ctx.load_verify_locations(cafile=a.ca)
    jar = http.cookiejar.CookieJar()
    manual = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                         urllib.request.HTTPCookieProcessor(jar), NoRedirect)
    auto = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                       urllib.request.HTTPCookieProcessor(jar))

    def hop(opener, url, data=None, headers=None):
        req = urllib.request.Request(url, data=data, method="POST" if data else "GET",
                                     headers={"User-Agent": "ingress-signin-test", **(headers or {})})
        # The headers as http.client parsed them, which match case-insensitively: managed login
        # answers the sign-in POST with a lowercase `location`, which a plain dict lookup missed.
        try:
            r = opener.open(req, timeout=60)
            return r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()

    print("1. unauthenticated request")
    code, h, _ = hop(manual, f"https://{a.host}/")
    loc = h.get("Location", "")
    print(f"   HTTP {code} server={h.get('Server')} -> {loc[:100]}")
    if code not in (301, 302, 303, 307) or a.idp not in loc:
        print("FAIL: not redirected to the identity provider")
        return 1

    print("2. hosted login page")
    # Follow the redirects by hand and keep the URL the form is actually on: with a federated
    # provider the login page is the PROVIDER's, one or more hops past the ingress component's own pool,
    # and posting the form to the pool's host lands on its /error page.
    page_url = loc
    for _ in range(8):
        code, h, body = hop(manual, page_url)
        nxt = h.get("Location", "")
        if code not in (301, 302, 303, 307) or not nxt:
            break
        page_url = nxt if nxt.startswith("http") else urllib.parse.urljoin(page_url, nxt)
    page = body.decode("utf-8", "replace")
    # Two login pages. The classic hosted UI names its token `_csrf`; managed login (the pool's
    # domain at version 2, which person_access_delegated_token turns on) names it `csrf` and adds an
    # empty `cognitoAsfData`. Both take username and password in the same POST.
    csrf = re.search(r'name="(_?csrf)"\s+value="([^"]+)"', page)
    action = re.search(r'<form[^>]*\saction="([^"]+)"', page) or re.search(r'action="([^"]+)"', page)
    if not csrf or not action:
        print(f"FAIL: HTTP {code}, no login form on the provider's page")
        return 1
    # HTML-escaped, and carrying a literal space (`scope=openid email`), which http.client refuses.
    action_url = urllib.parse.quote(action.group(1).replace("&amp;", "&"), safe="/?&=%+:,")
    origin = "{0.scheme}://{0.netloc}".format(urllib.parse.urlsplit(page_url))

    print("3. credentials")
    fields = {csrf.group(1): csrf.group(2), "username": a.user, "password": password}
    if 'name="cognitoAsfData"' in page:
        fields["cognitoAsfData"] = ""
    form = urllib.parse.urlencode(fields).encode()
    code, h, _ = hop(manual, origin + action_url, data=form,
                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    back = h.get("Location", "")
    print(f"   HTTP {code}")
    # FEDERATED SIGN-IN HAS MORE HOPS. With ingress_idp = "oidc" the provider hands the person
    # back to the ingress Cognito pool (/oauth2/idpresponse), which then redirects to the load
    # balancer's own /oauth2/idpresponse. Follow redirects until the one aimed at THIS host carries
    # the code, at most eight hops.
    for _ in range(8):
        if "code=" in back and urllib.parse.urlsplit(back).netloc == a.host:
            break
        if not back:
            break
        print(f"   -> {back[:100]}")
        code, h, _ = hop(manual, back)
        back = h.get("Location", "")
    if "code=" not in back or urllib.parse.urlsplit(back).netloc != a.host:
        print(f"FAIL: no authorization code came back to {a.host}; the login did not succeed (last: {back[:120]})")
        return 1

    print("4. code exchange at the load balancer")
    code, h, _ = hop(manual, back)
    if "AWSELBAuthSessionCookie" not in " ".join(h.get_all("Set-Cookie") or []):
        print(f"FAIL: HTTP {code}, no AWSELBAuthSessionCookie")
        return 1
    print(f"   HTTP {code}, session cookie set")

    print("5. the UI, with the identity it verified")
    code, h, body = hop(auto, f"https://{a.host}/")
    page = body.decode("utf-8", "replace")
    who = re.search(r'<span class="who">([^<]*)</span>', page)
    who = who.group(1).strip() if who else ""
    print(f"   HTTP {code} server={h.get('Server')} identity={who!r}")
    if code != 200:
        print("FAIL: the UI refused a signed-in person. A 401 from uvicorn here is the UI's own check")
        print("      of x-amzn-oidc-data (signer, client, expiry) refusing the load balancer's claims.")
        return 1
    if a.expect and who != a.expect:
        print(f"FAIL: the UI reports {who!r}, expected {a.expect!r}")
        return 1

    print("6. a turn relayed to an agent")
    code, h, body = hop(auto, f"https://{a.host}/chat?agent={urllib.parse.quote(a.agent)}",
                        data=json.dumps({"prompt": "Reply with the single word: reachable"}).encode(),
                        headers={"Content-Type": "application/json"})
    text = body.decode("utf-8", "replace").replace("\n", " ")
    print(f"   HTTP {code}: {text[:200]}")
    if code != 200:
        print("FAIL: the turn was not relayed")
        return 1
    for n, prompt in enumerate(a.turn, 1):
        if a.turn_wait:
            time.sleep(a.turn_wait)
        code, h, body = hop(auto, f"https://{a.host}/chat?agent={urllib.parse.quote(a.agent)}",
                            data=json.dumps({"prompt": prompt}).encode(),
                            headers={"Content-Type": "application/json"})
        reply = ""
        for line in body.decode("utf-8", "replace").splitlines():
            if line.startswith("data:") and line[5:].strip() not in ("", "[DONE]"):
                try:
                    o = json.loads(line[5:])
                    reply += o.get("delta", "") or (f"[error] {o['error']}" if o.get("error") else "")
                except ValueError:
                    pass
        print(f"REPLY {n}: HTTP {code} {reply.strip()[:300]!r}")
        if code != 200:
            print(f"FAIL: turn {n} was not relayed")
            return 1
    print("PASS: signed in, verified, and relayed a turn")
    return 0


if __name__ == "__main__":
    sys.exit(main())
