"""Read public plugin results without loading credentials or printing signed media URLs."""
import json
import subprocess
import argparse
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

app = "/Applications/MacTV.app/Contents/"
parser = argparse.ArgumentParser()
parser.add_argument("--plugin-root", default=app + "Resources/plugins/bilibili")
parser.add_argument("--transport", choices=["dash", "progressive"])
parser.add_argument("--reference")
parser.add_argument("--inspect-header", action="store_true")
options = parser.parse_args()


def execute(action, args):
    result = subprocess.run([app + "MacOS/MTVPluginHost", options.plugin_root],
                            input=json.dumps({"action": action, "input": args}), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=True)
    envelope = json.loads(result.stdout)
    if "error" in envelope:
        raise RuntimeError(envelope["error"])
    return envelope.get("result", envelope.get("data"))


try:
    page = execute("browse", {}) if not options.reference else {"items": []}
    first = page["items"][0] if page["items"] else {}
    values = {"reference": options.reference or first.get("reference", first.get("id"))}
    if options.transport:
        values["transport"] = options.transport
    stream = execute("resolve", values)
    url = urlsplit(stream["url"])
    print(json.dumps({"browseCount": len(page["items"]), "quality": stream.get("quality"),
                      "scheme": url.scheme, "host": url.hostname, "port": url.port,
                      "pathSuffix": url.path.rsplit(".", 1)[-1],
                      "headerNames": sorted(stream.get("headers", {})),
                      "hasSeparateAudio": bool(stream.get("audioURL")), "note": stream.get("note")}))
    if options.inspect_header:
        for role, value in [("video", stream["url"]), ("audio", stream.get("audioURL"))]:
            if not value:
                continue
            headers = dict(stream.get("headers", {}))
            headers["Range"], headers["Accept-Encoding"] = "bytes=0-262143", "identity"
            with urlopen(Request(value, headers=headers), timeout=12) as response:
                data = response.read(262144)
            observations = []

            def boxes(start, end, depth=0):
                offset = start
                while offset + 8 <= end and len(observations) < 160:
                    size = int.from_bytes(data[offset:offset+4], "big")
                    kind = data[offset+4:offset+8].decode("ascii", errors="replace")
                    header = 8
                    if size == 1:
                        if offset + 16 > end:
                            return
                        size = int.from_bytes(data[offset+8:offset+16], "big"); header = 16
                    if size == 0:
                        size = end - offset
                    if size < header:
                        return
                    record = {"type": kind, "offset": offset, "size": size}
                    body = offset + header
                    if kind in ["mvhd", "mdhd"] and body + 32 <= len(data):
                        version = data[body]
                        pos = body + (20 if version == 1 else 12)
                        record["timescale"] = int.from_bytes(data[pos:pos+4], "big")
                        record["duration"] = int.from_bytes(data[pos+4:pos+(12 if version == 1 else 8)], "big")
                    observations.append(record)
                    if offset + size > end:
                        return
                    if kind in ["moov", "trak", "mdia", "mvex", "edts"] and depth < 5:
                        boxes(body, offset + size, depth+1)
                    offset += size

            boxes(0, len(data))
            print(json.dumps({"role": role, "boundedHeaderBytes": len(data), "boxes": observations}))
except Exception as error:
    print(json.dumps({"error": str(error)}))
