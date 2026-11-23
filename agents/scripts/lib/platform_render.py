#!/usr/bin/env python3
"""The platform's Argo CD Applications, rendered the way the root Application renders them.

    platform_render.py render <repo root> <outdir>   # outdir/<path>/NN-x.yaml, both paths, and
                                                     # outdir/<path>/alternatives/... for each
                                                     # alternative that is a template
    platform_render.py check  <repo root>            # each platform chart renders, and each
                                                     # template's `excluded` wrapper is its own

gitops/platform/<path> is a Helm chart whose templates are the Applications, so a check that reads
the files reads Go templates rather than manifests. Every check reads the render instead, from here,
so they all see the same values: each committed values file under the key the root Application gives
it (scripts/lib/root-app.sh), the repository from the chart's values.yaml, and `excluded: []`, so every
Application is present whichever layers a deployment turns off.

As a module:

    import platform_render
    platform_render.render(root, "open-source")        # {"00-base.yaml": [docs], ...}
    platform_render.applications(root, "open-source")  # {"eks-agents-base": doc, ...}

A render is done once per process and path. validate.sh renders once for the whole run and sets
PLATFORM_RENDER_DIR, so every check it starts reads that one render.
"""
from __future__ import annotations

import atexit
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

PATHS = ("open-source", "aws-services")

# The same keys, and the same files, the root Application folds in (scripts/lib/root-app.sh).
VALUES_FILES = {
    "terraform": "terraform-values.yaml",
    "collector": "collector-values.yaml",
    "externalDns": "external-dns-values.yaml",
    "agentEvals": "agent-evals-values.yaml",
}

_cache: dict[tuple[str, str], dict[str, list[dict]]] = {}


def chart_dir(root, path) -> pathlib.Path:
    return pathlib.Path(root).resolve() / "gitops" / "platform" / path


def template_files(root, path) -> list[str]:
    return sorted(p.name for p in (chart_dir(root, path) / "templates").glob("*.yaml"))


def values(root, path, excluded=(), overrides=None) -> dict:
    """The values the root Application passes, built from the committed values files."""
    chart = chart_dir(root, path)
    defaults = yaml.safe_load((chart / "values.yaml").read_text(encoding="utf-8")) or {}
    v = {"repo": dict(defaults.get("repo") or {}), "excluded": list(excluded)}
    for key, name in VALUES_FILES.items():
        f = chart / name
        if f.is_file():
            v[key] = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
    for key, val in (overrides or {}).items():
        v[key] = {**v.get(key, {}), **val} if isinstance(val, dict) else val
    return v


def _helm(root, path, vals, outdir: pathlib.Path) -> None:
    """Render into outdir as one file per template, named as the template is (NN-x.yaml)."""
    chart = chart_dir(root, path)
    work = pathlib.Path(tempfile.mkdtemp(prefix="platform-render-"))
    try:
        # JSON is YAML, and json.dumps cannot emit an alias or a tag helm would read differently.
        vf = work / "values.json"
        vf.write_text(json.dumps(vals), encoding="utf-8")
        res = subprocess.run(
            ["helm", "template", "root", str(chart), "-f", str(vf), "--output-dir", str(work / "out")],
            capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"helm template {chart} failed: {res.stderr.strip()}")
        outdir.mkdir(parents=True, exist_ok=True)
        # --output-dir writes <chart name>/templates/<file>; a template that renders nothing writes
        # no file at all, which is how an excluded one shows.
        for f in work.glob("out/*/templates/*.yaml"):
            shutil.copy(f, outdir / f.name)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def alternative_templates(root, path) -> list[pathlib.Path]:
    """The files under alternatives/ written as templates of this chart, to be copied into
    templates/ when chosen. They are not rendered where they sit, so they are rendered here."""
    alt = chart_dir(root, path) / "alternatives"
    return sorted(f for f in alt.rglob("*.yaml") if "{{" in f.read_text(encoding="utf-8"))


def render_alternatives(root, path, outdir: pathlib.Path) -> None:
    """Each alternative template, rendered as if it were in templates/, into outdir under its own
    relative path (alternatives/<dir>/<file>)."""
    chart = chart_dir(root, path)
    for f in alternative_templates(root, path):
        work = pathlib.Path(tempfile.mkdtemp(prefix="platform-alt-"))
        try:
            shutil.copytree(chart, work / chart.name, ignore=shutil.ignore_patterns("templates", "alternatives"))
            (work / chart.name / "templates").mkdir()
            shutil.copy(f, work / chart.name / "templates" / f.name)
            out = work / "out"
            # Rendered from the copy, with the same values the chart itself is rendered with.
            res = subprocess.run(
                ["helm", "template", "root", str(work / chart.name), "-f", "-", "--output-dir", str(out)],
                input=json.dumps(values(root, path)), capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError(f"helm template {f.relative_to(chart)} failed: {res.stderr.strip()}")
            dest = outdir / f.relative_to(chart)
            dest.parent.mkdir(parents=True, exist_ok=True)
            for r in out.glob(f"*/templates/{f.name}"):
                shutil.copy(r, dest)
        finally:
            shutil.rmtree(work, ignore_errors=True)


def _load(outdir: pathlib.Path) -> dict[str, list[dict]]:
    out = {}
    for f in sorted(outdir.glob("*.yaml")):
        out[f.name] = [d for d in yaml.safe_load_all(f.read_text(encoding="utf-8")) if d]
    return out


def render(root, path, excluded=(), overrides=None) -> dict[str, list[dict]]:
    """Rendered documents by template file name. Templates that render nothing are absent."""
    shared = not excluded and not overrides
    key = (str(pathlib.Path(root).resolve()), path)
    if shared and key in _cache:
        return _cache[key]
    if shared and os.environ.get("PLATFORM_RENDER_DIR"):
        pre = pathlib.Path(os.environ["PLATFORM_RENDER_DIR"]) / path
        if pre.is_dir():
            _cache[key] = _load(pre)
            return _cache[key]
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="platform-"))
    atexit.register(shutil.rmtree, tmp, True)
    _helm(root, path, values(root, path, excluded, overrides), tmp / path)
    docs = _load(tmp / path)
    if shared:
        _cache[key] = docs
    return docs


def applications(root, path, **kw) -> dict[str, dict]:
    return {d["metadata"]["name"]: d for docs in render(root, path, **kw).values()
            for d in docs if d.get("kind") == "Application"}


def source_documents(text: str) -> int:
    """How many YAML documents a template's source has: `---`-separated chunks with any content
    that is neither a comment nor a template action on its own line."""
    n = 0
    for chunk in re.split(r"(?m)^---[ \t]*$", text):
        if any(l.strip() and not l.lstrip().startswith("#") and not re.fullmatch(r"\s*\{\{.*\}\}\s*", l)
               for l in chunk.splitlines()):
            n += 1
    return n


def check(root) -> int:
    """Each chart renders; `excluded` set to every template renders nothing, set to one template
    removes exactly that one, and empty renders one Application per source document."""
    errs = []
    for path in PATHS:
        before = len(errs)
        files = template_files(root, path)
        try:
            full = render(root, path)
            none = render(root, path, excluded=files)
        except RuntimeError as e:
            errs.append(f"{path}: {e}")
            continue
        if none:
            errs.append(f"{path}: with every template excluded, {sorted(none)} still render")
        apps = 0
        for f in files:
            want = source_documents((chart_dir(root, path) / "templates" / f).read_text(encoding="utf-8"))
            got = full.get(f, [])
            kinds = [d.get("kind") for d in got]
            if len(got) != want or any(k != "Application" for k in kinds):
                errs.append(f"{path}/templates/{f}: {want} source document(s), rendered {kinds}")
            apps += len(got)
            # Excluding one file removes that file and nothing else, so a wrapper that names a
            # sibling's file is caught: that layer's toggle would remove the wrong Application.
            one = render(root, path, excluded=[f])
            if f in one or sorted(one) != sorted(k for k in full if k != f):
                errs.append(f"{path}/templates/{f}: excluding it renders {sorted(one)}")
        if len(errs) == before:
            print(f"      ✓ {path}: {len(files)} templates, {apps} Applications, each excluded by its own name")
    for e in errs:
        print(f"      ✗ {e}")
    return 1 if errs else 0


def main(argv) -> int:
    if len(argv) >= 3 and argv[0] == "render":
        try:
            for path in PATHS:
                _helm(argv[1], path, values(argv[1], path), pathlib.Path(argv[2]) / path)
                render_alternatives(argv[1], path, pathlib.Path(argv[2]) / path)
        except RuntimeError as e:
            print(f"      ✗ {e}")
            return 1
        return 0
    if len(argv) >= 2 and argv[0] == "check":
        return check(argv[1])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
