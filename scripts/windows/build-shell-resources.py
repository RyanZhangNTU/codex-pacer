"""Package authoritative catalogs and browser programs for the WPF host."""
import argparse,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def outputs():
    for language in ("en","zh-Hans"):
        catalog=json.loads((ROOT/f"windows/EngineSupport/Resources/Localization/Catalogs/{language}.json").read_text(encoding="utf8"))
        yield ROOT/f"windows/Desktop/Assets/Localization/{language}.json", {"schemaVersion":1,"language":language,"strings":catalog["strings"]}
    resources=ROOT/"native/Sources/PacerCore/Resources"
    yield ROOT/"windows/Desktop/Assets/Web/deepseek-scripts.json", {"schemaVersion":1,"origin":"https://platform.deepseek.com/",
        "summaryScript":(resources/"deepseek-summary.js").read_text(encoding="utf8"),
        "signedInScript":(resources/"deepseek-session-fingerprint.js").read_text(encoding="utf8")}
if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--check",action="store_true");args=parser.parse_args()
    for path,value in outputs():
        data=json.dumps(value,ensure_ascii=False,sort_keys=True,indent=2)+"\n"
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf8")!=data: raise SystemExit("WPF resources differ from shared sources: "+path.name)
        else:
            path.parent.mkdir(parents=True,exist_ok=True);path.write_text(data,encoding="utf8")
    print("WPF resources match the shared sources.")
