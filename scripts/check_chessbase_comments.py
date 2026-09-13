"""Exercise JSON escaping through a real CBH annotation record."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

fixtures, reader = map(Path, sys.argv[1:3])
with tempfile.TemporaryDirectory(prefix="lucent-comment-check-") as temporary:
    directory = Path(temporary) / "annotations"
    shutil.copytree(fixtures / "annotations", directory)
    annotation = directory / "TestBase.cba"
    original = b"This is a text after move comment"
    replacement = 'Line1\nTab\t"quoted" \\ caf\u00e9'.encode("cp1252").ljust(len(original), b" ")
    assert len(replacement) == len(original)
    data = annotation.read_bytes()
    assert data.count(original) == 1
    annotation.write_bytes(data.replace(original, replacement))
    output = Path(temporary) / "games.json"
    subprocess.run([str(reader), str(directory / "TestBase.cbh"), str(output), "0", "256"], check=True)
    decoded = json.loads(output.read_text())
    comments = [move["after"] for game in decoded["games"] for move in game["moves"]]
    assert any(comment.rstrip() == replacement.decode("cp1252").rstrip() for comment in comments)
    print("Passed: multiline, tab, quote, backslash and Windows-1252 comments survive reader JSON")
