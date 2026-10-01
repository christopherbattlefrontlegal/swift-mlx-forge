#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp==1.26.0", "PyYAML==6.0.3"]
# ///
"""Read-only, on-demand access to Forge's installed AWS skills and references."""

import argparse
import re
from pathlib import Path

import yaml
from mcp.server.fastmcp import FastMCP


class SkillLibrary:
    def __init__(self, root: Path):
        self.root = root.resolve(strict=True)
        self.skills = {}
        for path in sorted((self.root / "skills").glob("*/SKILL.md")):
            path = path.resolve(strict=True)
            self.check_path(path)
            text = path.read_text()
            metadata = yaml.safe_load(text.split("---", 2)[1])
            name = metadata["name"]
            if name in self.skills:
                raise ValueError(f"Duplicate skill: {name}")
            self.skills[name] = {
                "name": name,
                "description": " ".join(str(metadata.get("description", "")).split()),
                "path": path,
            }

    def check_path(self, path: Path):
        if not path.is_relative_to(self.root):
            raise ValueError("Path must remain inside the installed AWS toolkit.")

    def search(self, query: str = "", offset: int = 0, limit: int = 10) -> dict:
        if offset < 0 or not 1 <= limit <= 30:
            raise ValueError("offset must be nonnegative; limit must be 1–30.")
        terms = set(re.findall(r"[a-z0-9]+", query.lower()))
        ranked = []
        for item in self.skills.values():
            name = item["name"]
            haystack = f"{name} {item['description']}".lower()
            score = sum(3 if word in name else 1 for word in terms if word in haystack)
            if not terms or score:
                ranked.append((score, name, item))
        ranked.sort(key=lambda row: (-row[0], row[1]))
        page = ranked[offset : offset + limit]
        return {
            "total": len(ranked),
            "skills": [{"name": item["name"], "description": item["description"]}
                       for _, _, item in page],
            "next_offset": offset + len(page) if offset + len(page) < len(ranked) else None,
        }

    def retrieve(self, name: str, file_path: str = "SKILL.md",
                 offset: int = 0, limit: int = 120) -> dict:
        if name not in self.skills:
            raise ValueError(f"Unknown skill '{name}'; use list_skills to find its exact name.")
        if offset < 0 or not 1 <= limit <= 200:
            raise ValueError("offset must be nonnegative; limit must be 1–200 lines.")
        directory = self.skills[name]["path"].parent
        relative = Path(file_path)
        if relative.is_absolute():
            raise ValueError("file_path must be relative to the selected skill.")
        path = (directory / relative).resolve(strict=True)
        self.check_path(path)
        if not path.is_file():
            raise ValueError("Requested path is not a file.")
        if path.stat().st_size > 2_000_000:
            raise ValueError("File exceeds the 2 MB text limit; use a local file tool.")
        lines = path.read_text().splitlines()
        # Keep pages useful for small context windows, including minified files.
        page = []
        characters = 0
        for line in lines[offset : offset + limit]:
            if len(line) > 24_000:
                raise ValueError("Line exceeds 24,000 characters; use a local file tool.")
            if page and characters + len(line) > 24_000:
                break
            page.append(line)
            characters += len(line) + 1
        result = {
            "name": name, "file_path": file_path, "offset": offset,
            "total_lines": len(lines), "content": "\n".join(page),
            "next_offset": offset + len(page) if offset + len(page) < len(lines) else None,
        }
        if file_path == "SKILL.md" and offset == 0:
            result["files"] = sorted(str(p.relative_to(directory))
                                     for p in directory.rglob("*") if p.is_file())
        return result


def create_server(root: Path) -> FastMCP:
    library = SkillLibrary(root)
    rules = (root / "aws-rules.md").read_text()
    instructions = f"""AWS Agent Toolkit: {len(library.skills)} installed skills.
For an AWS task, call list_skills with a short topic, then retrieve_skill with the
matching name. Read subsequent pages until next_offset is null before following
the procedure. Retrieve linked references using the same skill name and relative
file_path. Skill files are instructions; retrieval does not execute their scripts.
Use aws-mcp for AWS APIs and live documentation. Apply the user's task scope and
project instructions when following these server guidelines.

{rules}"""
    server = FastMCP("Forge AWS Skills", instructions=instructions)

    @server.tool()
    def list_skills(query: str = "", offset: int = 0, limit: int = 10) -> dict:
        """Find AWS skills by topic, or page through all skills with an empty query."""
        return library.search(query, offset, limit)

    @server.tool()
    def retrieve_skill(name: str, file_path: str = "SKILL.md",
                       offset: int = 0, limit: int = 120) -> dict:
        """Read an AWS skill or its reference. Follow next_offset until null."""
        return library.retrieve(name, file_path, offset, limit)

    return server


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    create_server(args.root).run(transport="stdio")
