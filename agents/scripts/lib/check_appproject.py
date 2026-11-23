#!/usr/bin/env python3
"""The eks-agents AppProject admits exactly the repositories and the cluster the platform uses.

    python3 scripts/lib/check_appproject.py <repo root>

gitops/bootstrap/<path>/appproject.yaml lists the project's sourceRepos: REPO_URL (the platform
repository, which Terraform fills in from gitops_repo_url), every chart and manifest repository a
platform Application reads, and the EXTRA_SOURCE_REPOS line Terraform replaces with
argocd_extra_source_repos. Argo CD refuses an Application whose repoURL the project does not list,
and the refusal surfaces only at sync, on a cluster. So this renders every platform Application
(scripts/lib/platform_render.py, every layer on, and each alternative under alternatives/) and fails
when:

  - an Application reads a repository the project does not list, spelled as its repoURL spells it
    (a new component whose repository was not added);
  - the project lists a repository no Application reads (an entry left behind widens the project);
  - the project names "*" as a source, or a destination other than the cluster the platform
    registers, or an Application names a destination the project does not admit;
  - the EXTRA_SOURCE_REPOS line Terraform replaces is missing, so argocd_extra_source_repos would
    be silently dropped.
"""
import pathlib
import sys
import tempfile

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import platform_render  # noqa: E402  the platform's Applications, rendered


def sources(app):
    spec = app.get("spec") or {}
    return spec.get("sources") or ([spec["source"]] if "source" in spec else [])


def project(root, path):
    f = pathlib.Path(root) / "gitops/bootstrap" / path / "appproject.yaml"
    text = f.read_text(encoding="utf-8")
    docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict) and d.get("kind") == "AppProject"]
    return f, text, (docs[0] if docs else None)


def main(root):
    root = pathlib.Path(root).resolve()
    errs, used_total = [], 0
    for path in platform_render.PATHS:
        f, text, proj = project(root, path)
        where = f.relative_to(root)
        if proj is None:
            errs.append(f"{where}: no AppProject")
            continue
        spec = proj.get("spec") or {}
        listed = list(spec.get("sourceRepos") or [])
        if "*" in listed:
            errs.append(f"{where}: sourceRepos lists \"*\", so the project admits any repository")
        if "REPO_URL" not in listed:
            errs.append(f"{where}: sourceRepos does not start from REPO_URL, the platform repository")
        if "    # EXTRA_SOURCE_REPOS" not in text.splitlines():
            errs.append(f"{where}: no '    # EXTRA_SOURCE_REPOS' line, so Terraform has nowhere to put argocd_extra_source_repos")
        dests = spec.get("destinations") or []
        if dests != [{"name": "eks-agents", "namespace": "*"}]:
            errs.append(f"{where}: destinations {dests!r}, not only the cluster the platform registers (name eks-agents)")
        admitted = {d.get("name") for d in dests if d.get("name")}

        # Every Application the platform chart renders, and each alternative a reader may copy in.
        own = platform_render.values(root, path)["repo"]["url"]
        apps = list(platform_render.applications(root, path).values())
        with tempfile.TemporaryDirectory(prefix="appproject-alt-") as tmp:
            platform_render.render_alternatives(root, path, pathlib.Path(tmp))
            for alt in pathlib.Path(tmp).rglob("*.yaml"):
                apps += [d for d in yaml.safe_load_all(alt.read_text(encoding="utf-8"))
                         if isinstance(d, dict) and d.get("kind") == "Application"]

        used = {}
        for app in apps:
            name = app["metadata"]["name"]
            dest = (app.get("spec") or {}).get("destination") or {}
            if dest.get("name") not in admitted or "server" in dest:
                errs.append(f"gitops/platform/{path}: Application {name} has destination {dest!r}, which the project does not admit")
            if (app.get("spec") or {}).get("project") != proj["metadata"]["name"]:
                errs.append(f"gitops/platform/{path}: Application {name} names project {app['spec'].get('project')!r}")
            for s in sources(app):
                url = s.get("repoURL")
                if url:
                    used.setdefault("REPO_URL" if url == own else url, set()).add(name)
        used_total += len(used)

        for url, names in sorted(used.items()):
            if url not in listed:
                errs.append(f"{where}: sourceRepos does not list {url!r}, which {', '.join(sorted(names))} read(s)")
        for url in listed:
            if url not in used:
                errs.append(f"{where}: sourceRepos lists {url!r}, which no platform Application reads")

    for e in errs:
        print(f"      ✗ {e}")
    if not errs:
        print(f"      ✓ both AppProjects list exactly the {used_total} repositories their Applications read, and admit only the eks-agents destination")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
