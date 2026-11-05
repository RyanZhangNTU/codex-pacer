"""Give the Sparkle tools the update signing key.

On the release Mac the key stays in the login Keychain under the app's account.
The Release workflow passes it in SPARKLE_PRIVATE_KEY instead, and the tools read
it from standard input, so it never reaches a file, a log or an argument list.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ACCOUNT = "com.codexpacer.app"
ENVIRONMENT = "SPARKLE_PRIVATE_KEY"
DERIVE = Path(__file__).with_name("sparkle-public-key.swift")


def _secret():
    return os.environ.get(ENVIRONMENT, "").strip()


def run(tool, *arguments, capture=False):
    """Run a Sparkle tool with the signing key; raises on failure and returns standard output when captured."""
    secret = _secret()
    source = ["--ed-key-file", "-"] if secret else ["--account", ACCOUNT]
    result = subprocess.run([str(tool), *source, *map(str, arguments)], input=secret + "\n" if secret else None,
                            stdout=subprocess.PIPE if capture else None, text=True, check=True)
    return result.stdout


def public_key(tools):
    """The public half of the signing key, to compare with the app's SUPublicEDKey."""
    secret = _secret()
    if secret:
        public = subprocess.run(["xcrun", "swift", str(DERIVE)], input=secret + "\n", stdout=subprocess.PIPE,
                                text=True, check=True).stdout.strip()
        # A legacy key carries its public half; prove the pair by verifying a fresh signature with it.
        with tempfile.NamedTemporaryFile(prefix="pacer-key-probe-") as probe:
            probe.write(os.urandom(64)); probe.flush()
            signature = run(Path(tools) / "sign_update", "-p", probe.name, capture=True).strip()
            subprocess.run(["xcrun", "swift", str(DERIVE), "--verify", public, signature, probe.name], check=True)
        return public
    return subprocess.check_output([str(Path(tools) / "generate_keys"), "--account", ACCOUNT, "-p"], text=True).strip()
