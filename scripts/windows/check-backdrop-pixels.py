#!/usr/bin/env python3
"""Compare protected synthetic desktop captures outside the recorded contour."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def check(root: Path) -> list[dict]:
    data = json.loads((root / "acceptance.json").read_text(encoding="utf-8-sig"))
    results = []
    for capture in data["captures"]:
        name = capture["name"]
        # Both motion and injected fallback captures use the dark synthetic scene.
        theme = "light" if "light" in name else "dark"
        image = np.asarray(Image.open(root / f"{name}.png").convert("RGB")).astype(int)
        reference = np.asarray(Image.open(root / f"reference-{theme}.png").convert("RGB")).astype(int)
        if image.shape != reference.shape:
            raise AssertionError(f"{name}: reference dimensions differ")
        polygon = list(zip(capture["Polygon"][::2], capture["Polygon"][1::2]))
        # Rasterize at 4x; exclude one device pixel at the antialiased edge.
        scale = 4
        mask = Image.new("L", (image.shape[1] * scale, image.shape[0] * scale))
        points = [((x + capture["x"]) * scale, (y + capture["y"]) * scale) for x, y in polygon]
        ImageDraw.Draw(mask).polygon(points, fill=255)
        mask = mask.filter(ImageFilter.MaxFilter(2 * scale + 1)).resize((image.shape[1], image.shape[0]), Image.Resampling.BOX)
        outside = np.asarray(mask) == 0
        difference = np.abs(image - reference).max(axis=2)
        results.append({"name": name, "outsidePixels": int(outside.sum()), "outsideChangedPixels": int(np.count_nonzero(difference[outside])),
                        "outsideMaxDifference": int(difference[outside].max()), "excludedAntialiasPixels": 1})
    (root / "outside-pixels.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    rows = check(args.directory)
    print(json.dumps(rows, indent=2))
    if any(row["outsideChangedPixels"] for row in rows):
        raise SystemExit("Pixels changed outside the island contour.")
