"""Pure helpers for selecting a Flutter toolchain version.

Kept in its own module (rather than the script-generated versions.bzl) so the
logic is stable and unit-testable in isolation. See
//flutter/tests:version_select_test.
"""

def version_sort_key(raw):
    """Return a comparable key for a Flutter version string.

    Splits on '.', taking the leading integer of each segment and stopping at
    the first non-numeric segment (so pre-release/build suffixes like
    "3.24.0-1.2.pre" compare on their numeric prefix). Lists of ints compare
    element-wise, giving true semver ordering rather than the lexicographic
    ordering of raw strings (where e.g. "3.9.0" wrongly sorts above "3.35.0"
    and "3.38.10" wrongly sorts below "3.38.9").

    Args:
        raw: a version string such as "3.38.10".

    Returns:
        A list of ints suitable as a sort key.
    """
    parts = []
    for segment in raw.split("."):
        if "-" in segment:
            # Pre-release / build boundary (e.g. "0-1.2.pre"): keep this
            # segment's numeric head, then stop — everything after is a
            # pre-release qualifier we don't rank.
            head = segment.split("-")[0]
            if head.isdigit():
                parts.append(int(head))
            break
        if segment.isdigit():
            parts.append(int(segment))
        else:
            break
    return parts

def highest_version(versions):
    """Return the highest version from an iterable, compared semver-aware.

    Args:
        versions: an iterable of version strings.

    Returns:
        The single highest version string, or None if the iterable is empty.
    """
    ordered = sorted(versions, key = version_sort_key, reverse = True)
    return ordered[0] if ordered else None
