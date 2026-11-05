"""Development-only SMB2 fixture. Loopback only; no real media or user credentials."""
import argparse
import logging
from pathlib import Path
from impacket.smbserver import SimpleSMBServer

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True)
parser.add_argument("--port", type=int, default=1445)
args = parser.parse_args()
root = Path(args.root).resolve()
root.mkdir(parents=True, exist_ok=True)
(root / "MTV-test.txt").write_text("MTV SMB fixture\n")
(root / "Movies").mkdir(exist_ok=True)
logging.getLogger().setLevel(logging.CRITICAL)
server = SimpleSMBServer(listenAddress="127.0.0.1", listenPort=args.port)
server.setSMB2Support(True)
server.addShare("MTVFixture", str(root), readOnly="yes")
print("Loopback-only read-only SMB fixture ready", flush=True)
server.start()
