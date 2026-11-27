import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PATCH = Path("apps/desktop-flutter/windows/window_manager-0.5.2-fullscreen.patch")


@unittest.skipUnless(shutil.which("git"), "Git is required to apply the Windows plugin patch")
class WindowsFullscreenPatchCheckoutTests(unittest.TestCase):
    def test_clean_checkout_patch_is_parseable_with_windows_and_unix_settings(self):
        for autocrlf in ("true", "input"):
            with self.subTest(autocrlf=autocrlf), tempfile.TemporaryDirectory(
                prefix="webhtv-fullscreen-patch-"
            ) as temporary:
                repo = Path(temporary) / "repo"
                exported = Path(temporary) / "checkout"
                repo.mkdir()
                environment = os.environ.copy()
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
                environment["GIT_CONFIG_GLOBAL"] = os.devnull

                def git(*arguments, check=True):
                    return subprocess.run(
                        ["git", "-c", f"core.autocrlf={autocrlf}", *arguments],
                        cwd=repo, env=environment, capture_output=True, text=True,
                        encoding="utf-8", timeout=20, check=check,
                    )

                git("init", "--quiet")
                (repo / ".gitattributes").write_bytes((ROOT / ".gitattributes").read_bytes())
                target = repo / PATCH
                target.parent.mkdir(parents=True)
                target.write_bytes((ROOT / PATCH).read_bytes().replace(b"\r\n", b"\n"))
                git("add", ".gitattributes", str(PATCH))
                git("checkout-index", "--all", f"--prefix={exported.as_posix()}/")

                result = git("apply", "--numstat", str(exported / PATCH), check=False)
                self.assertEqual(
                    0, result.returncode,
                    f"Fresh core.autocrlf={autocrlf} checkout corrupts the build patch: "
                    f"{result.stderr.strip()}",
                )
                patched_files = {line.split("\t")[-1] for line in result.stdout.splitlines()}
                self.assertEqual(
                    {"window_manager.cpp", "window_manager_plugin.cpp"}, patched_files
                )


if __name__ == "__main__":
    unittest.main()
