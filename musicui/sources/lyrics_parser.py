import re

LINE_RE = re.compile(r"\[(\d+):(\d+\.\d+)\](.*)")
WORD_TS_RE = re.compile(r"<(\d+):(\d+\.\d+)>")


def _ts_to_sec(minutes, seconds):
    return int(minutes) * 60 + float(seconds)


def is_word_level(lrc_text):
    return bool(WORD_TS_RE.search(lrc_text))


def parse_line_level(lrc_text):
    raw = []
    for line in lrc_text.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        minutes, seconds, text = m.groups()
        ts = _ts_to_sec(minutes, seconds)
        raw.append((ts, text.strip()))

    raw.sort(key=lambda x: x[0])

    result = []
    for i, (ts, text) in enumerate(raw):
        end = raw[i + 1][0] if i + 1 < len(raw) else ts + 5
        result.append((ts, end, text))
    return result


def parse_word_level(lrc_text):
    words = []
    line_id = 0

    for line in lrc_text.splitlines():
        line_match = LINE_RE.match(line)
        if not line_match:
            continue

        line_id += 1
        _, _, rest = line_match.groups()

        tokens = re.split(r"(<\d+:\d+\.\d+>)", rest)
        current_ts = None
        buffer = ""

        parsed_words = []
        for token in tokens:
            ts_match = WORD_TS_RE.match(token)
            if ts_match:
                if current_ts is not None and buffer.strip():
                    parsed_words.append((current_ts, buffer.strip()))
                minutes, seconds = ts_match.groups()
                current_ts = _ts_to_sec(minutes, seconds)
                buffer = ""
            else:
                buffer += token

        if current_ts is not None and buffer.strip():
            parsed_words.append((current_ts, buffer.strip()))

        for i, (ts, word) in enumerate(parsed_words):
            end = parsed_words[i + 1][0] if i + 1 < len(parsed_words) else ts + 0.5
            words.append((ts, end, word, line_id))

    return words


def parse_lyrics(lrc_text):
    if is_word_level(lrc_text):
        return "word", parse_word_level(lrc_text)
    return "line", parse_line_level(lrc_text)