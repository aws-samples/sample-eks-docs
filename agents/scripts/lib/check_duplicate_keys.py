#!/usr/bin/env python3
"""Refuse a manifest with a duplicate mapping key.

    check_duplicate_keys.py <path> [<path> ...]

PyYAML's safe_load ACCEPTS duplicate keys and keeps the last one, so every other check in
validate.sh -- which parses with PyYAML -- passes a file kubectl will refuse outright:

    error: error validating data: ... found a duplicate key

A duplicated `command:` in an example's manifest passes every PyYAML-based check in
validate.sh. The same class of bug can take down an entire apply: when the file is the first entry
in an install list, `set -e` stops everything behind it.

So the parse step cannot be the one that catches this. This loader raises instead.
"""
import sys

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping")
    sys.exit(0)


class DuplicateKeyError(Exception):
    pass


class StrictLoader(yaml.SafeLoader):
    pass


def _no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            mark = key_node.start_mark
            raise DuplicateKeyError(
                f"line {mark.line + 1}: duplicate key {key!r}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicates)


def main():
    failed = 0
    checked = 0
    for path in sys.argv[1:]:
        try:
            with open(path, encoding="utf-8") as f:
                list(yaml.load_all(f, Loader=StrictLoader))
            checked += 1
        except DuplicateKeyError as e:
            print(f"      ✗ {path}: {e}")
            failed += 1
        except yaml.YAMLError:
            # A parse error that is not a duplicate key belongs to the parse step.
            checked += 1
    if not failed:
        print(f"      ✓ {checked} files, no duplicate mapping keys")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
