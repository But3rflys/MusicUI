from __future__ import annotations

import bisect


class LyricsBook:
    def __init__(self, mode=None, entries=None):
        self.mode = mode if entries else None
        self.lines = self._build(mode, entries or [])
        self._starts = [line["start"] for line in self.lines]

    def __bool__(self):
        return bool(self.lines)

    @staticmethod
    def _build(mode, entries):
        if not entries:
            return []

        if mode == "word":
            grouped: dict[int, list] = {}
            order: list[int] = []
            for start, end, word, line_id in entries:
                if line_id not in grouped:
                    grouped[line_id] = []
                    order.append(line_id)
                grouped[line_id].append((start, end, word))

            lines = []
            for line_id in order:
                words = sorted(grouped[line_id], key=lambda w: w[0])
                lines.append({
                    "start": words[0][0],
                    "end": words[-1][1],
                    "text": " ".join(w[2] for w in words),
                    "words": [[round(s, 3), round(e, 3), w] for s, e, w in words],
                })
        else:
            lines = [
                {"start": start, "end": end, "text": text, "words": []}
                for start, end, text in entries
            ]

        lines.sort(key=lambda line: line["start"])

        for i, line in enumerate(lines):
            line["i"] = i
            if i + 1 < len(lines):
                line["end"] = min(line["end"], lines[i + 1]["start"])
            line["start"] = round(line["start"], 3)
            line["end"] = round(max(line["end"], line["start"] + 0.05), 3)

        return lines

    def index_at(self, position_sec: float) -> int:
        if not self.lines:
            return -1
        idx = bisect.bisect_right(self._starts, position_sec) - 1
        return idx

    def window(self, index: int, radius: int) -> list[dict]:
        if not self.lines:
            return []
        lo = max(0, index - radius)
        hi = min(len(self.lines), index + radius + 1)
        return self.lines[lo:hi]
