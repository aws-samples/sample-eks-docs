#!/usr/bin/env python3
"""Every Argo CD source that points INTO this repository reads the repository and revision it is given.

    python3 scripts/lib/check_inrepo_sources.py <repo root>

Two places name this repository, and each has one way to do it:

  gitops/bootstrap/<path>/root-app.yaml   the root Application says `repoURL: REPO_URL`,
                                          `targetRevision: REPO_REVISION` and a path under
                                          `REPO_PATHgitops/`, and passes the same three to the
                                          platform chart as repo.url, repo.revision and repo.path.
                                          Terraform's render rewrites exactly those placeholders.
  gitops/platform/<path>/templates/       every in-repo source says `{{ .Values.repo.url }}`,
                                          `{{ .Values.repo.revision }}` and a path under
                                          `{{ .Values.repo.path }}gitops/`.

A source carrying a concrete URL or branch instead is skipped by the render and syncs from wherever
it names, so the operator's reviewed repository does not govern it. The platform chart is checked by
rendering it with sentinel repo values: an in-repo source that does not come out with the sentinels
did not read them.

Why this exists: a test-branch copy of gitops/platform/aws-services/templates/45-platform-secrets.yaml,
with a test mirror's URL and branch substituted in, is easy to commit by mistake. Every aws-services
deployment then syncs the platform-secrets Application from a repository that does not exist in its
account, and the direct OIDC client secret is never delivered. Nothing reports it.
"""
import pathlib
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import platform_render  # noqa: E402  the platform's Applications, rendered

SENTINEL = {"url": "https://sentinel.invalid/repo.git", "revision": "sentinel-revision", "path": "sentinel-prefix/"}


def sources(app):
    spec = app.get("spec") or {}
    return spec.get("sources") or ([spec["source"]] if "source" in spec else [])


def in_repo(s, prefix):
    p = str(s.get("path", ""))
    return p.startswith(prefix + "gitops/") or p.startswith("gitops/") or "/gitops/" in p \
        or ("ref" in s and "chart" not in s)


def main(root):
    root = pathlib.Path(root)
    errs, checked = [], 0

    # The root Application: the placeholders Terraform renders, and the same three handed on.
    for f in sorted((root / "gitops/bootstrap").rglob("*.yaml")):
        if f.name.endswith(".local.yaml"):
            continue
        for doc in yaml.safe_load_all(f.read_text(encoding="utf-8")):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            where = f"{f.relative_to(root)}: Application {doc['metadata']['name']}"
            for s in sources(doc):
                if not in_repo(s, "REPO_PATH"):
                    continue
                checked += 1
                if s.get("repoURL") != "REPO_URL":
                    errs.append(f"{where}: in-repo source has repoURL {s.get('repoURL')!r}, not REPO_URL")
                if s.get("targetRevision") != "REPO_REVISION":
                    errs.append(f"{where}: in-repo source has targetRevision {s.get('targetRevision')!r}, not REPO_REVISION")
                if not str(s.get("path", "")).startswith("REPO_PATHgitops/"):
                    errs.append(f"{where}: in-repo source has path {s.get('path')!r}, not under REPO_PATHgitops/")
                if str(s.get("path", "")).startswith("REPO_PATHgitops/platform/"):
                    repo = (yaml.safe_load((s.get("helm") or {}).get("values") or "{}") or {}).get("repo") or {}
                    want = {"url": "REPO_URL", "revision": "REPO_REVISION", "path": "REPO_PATH"}
                    if repo != want:
                        errs.append(f"{where}: passes repo {repo!r} to the platform chart, not {want!r}")

    # The platform chart: every in-repo source reads repo.url, repo.revision and repo.path.
    for path in platform_render.PATHS:
        rendered = platform_render.render(root, path, overrides={"repo": SENTINEL})
        for name, docs in sorted(rendered.items()):
            for doc in docs:
                if doc.get("kind") != "Application":
                    continue
                where = f"gitops/platform/{path}/templates/{name}: Application {doc['metadata']['name']}"
                for s in sources(doc):
                    if not in_repo(s, SENTINEL["path"]):
                        continue
                    checked += 1
                    if s.get("repoURL") != SENTINEL["url"]:
                        errs.append(f"{where}: in-repo source has repoURL {s.get('repoURL')!r}, not {{{{ .Values.repo.url }}}}")
                    if s.get("targetRevision") != SENTINEL["revision"]:
                        errs.append(f"{where}: in-repo source has targetRevision {s.get('targetRevision')!r}, not {{{{ .Values.repo.revision }}}}")
                    if "path" in s and not str(s["path"]).startswith(SENTINEL["path"] + "gitops/"):
                        errs.append(f"{where}: in-repo source has path {s['path']!r}, not under {{{{ .Values.repo.path }}}}gitops/")

    for e in errs:
        print(f"      ✗ {e}")
    if not errs:
        print(f"      ✓ {checked} in-repo Application sources all read the repository and revision they are given")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
