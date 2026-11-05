"""Refresh the contributor blocks from the repository's public GitHub accounts."""

import json
import os
from pathlib import Path
import re
from urllib.request import Request, urlopen

START = "<!-- contributors:start -->"
END = "<!-- contributors:end -->"


def accounts():
    repository = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]
    for page in range(1, 11):
        url = f"https://api.github.com/repos/{repository}/contributors?per_page=100&page={page}"
        request = Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "MacTV-contributors",
        })
        with urlopen(request, timeout=20) as response:
            rows = json.load(response)
        for row in rows:
            login = row.get("login", "")
            if row.get("type") == "User" and re.fullmatch(r"[A-Za-z0-9-]{1,39}", login):
                yield login
        if len(rows) < 100:
            return
    raise RuntimeError("Contributor pagination exceeded the configured limit")


def update_readmes(logins):
    if not logins:
        raise RuntimeError("GitHub returned no public contributor accounts")
    avatars = "\n".join(
        f'<a href="https://github.com/{login}"><img src="https://github.com/{login}.png?size=64" '
        f'width="48" height="48" alt="{login}" /></a>'
        for login in dict.fromkeys(logins)
    )
    updates = {}
    for path in map(Path, ["README.md", "docs/README.en.md"]):
        text = path.read_text(encoding="utf-8")
        if text.count(START) != 1 or text.count(END) != 1:
            raise ValueError(f"Expected one contributor block in {path}")
        start = text.index(START) + len(START)
        end = text.index(END, start)
        updates[path] = text[:start] + "\n" + avatars + "\n" + text[end:]
    for path, text in updates.items():
        path.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    update_readmes(list(accounts()))
