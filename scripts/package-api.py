"""Create a deterministic source artifact without local caches, tests, or secrets."""
import hashlib
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
output = root / "build"
output.mkdir(exist_ok=True)
archive = output / "api.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
    for name in ("main.py", "models.py", "repository.py", "requirements.txt"):
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        bundle.writestr(info, (root / "api" / name).read_bytes())
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
versioned = output / f"api-{digest}.zip"
archive.replace(versioned)
print(versioned)
