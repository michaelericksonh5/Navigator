#!/usr/bin/env python3
"""Writes the art-words table into NavigatorCore.swift (ArtWords.tsv): the words Navigator letters into game art, in the
studio's shipped languages, as the localization team's dictionaries give them.

    python3 Tools/ArtWords/art_words.py <folder of en_to_<code>_dictionary.json files>

Only these words ship with Navigator; the dictionaries themselves are never copied into this repository. A word the
dictionaries do not have for a language is left out, and Navigator flags it rather than guessing. Re-run when the
dictionaries change, then rebuild.
"""
import json, os, re, sys, unicodedata

LANGS = ["fr", "es", "pt-br", "pt", "de", "it", "tr", "ru", "zh-cn", "zh-hk", "da", "sv", "sk", "ro", "pl", "no", "fi", "el",
         "cs", "bg", "nl", "ko", "ja"]
FILE_CODE = {"pt-br": "pt-BR", "zh-cn": "zh-CN", "zh-hk": "zh-HK", "es": "es-AR"}   # the studio's shipped Spanish art is Argentine Spanish

# Every word Navigator letters (PopUps, StandardPieces, wheels, pot plaques, the jackpot table, symbol words, feature cards).
TIERS = ["grand", "mega", "major", "minor", "mini", "micro"]
WIN_WORDS = ["big", "super", "mega", "huge", "epic", "massive", "ultra", "colossal", "gigantic", "insane", "legendary",
             "enormous", "monster", "sensational", "titanic"]
MODES = ["loot link", "super loot link", "lock and respin", "drum mode", "wysiwyg mode", "collect mode", "bonus collect mode",
         "super boost", "jackpot"]
ENGLISH = (["continue", "play now!", "power bet", "on", "off", "got it!", "total win", "bonus games awarded!",
            "bonus games complete", "one more chance", "press to spin", "jackpot wheel", "bonus wheel", "wheel",
            "jackpot wheel awarded!", "bonus wheel awarded!", "wheel awarded!", "jackpots", "bonus games", "multiplier",
            "credits", "wild bonus", "collector bonus", "multiplier bonus", "expand", "multi", "wilds", "jackpots or wilds",
            "respins", "collect", "fill the pots", "hot reel", "wild", "scatter", "bonus", "super bonus", "jackpot", "awarded!"]
           + TIERS + [f"you've won the {t} jackpot" for t in TIERS] + [f"{w} win!" for w in WIN_WORDS]
           + MODES + [f"{m} awarded!" for m in MODES])

def clean(s):
    s = "".join(ch for ch in s if unicodedata.category(ch) != "Cf")
    return re.sub(r"\s+", " ", s).strip()

def lookup(terms, en):
    # Navigator's English never says "free" (production says "bonus games"); the other languages may, so a
    # "bonus games" phrase the dictionaries have only in their "free games" wording takes that.
    for key in [en] + ([en.replace("bonus games", "free games")] if "bonus games" in en else []):
        if clean(terms.get(key, "")):
            return clean(terms[key])
        if not key.endswith("!") and clean(terms.get(key + "!", "")):  # kept as a shout: "one more chance!" for ONE MORE CHANCE
            return clean(terms[key + "!"]).rstrip("!\uff01 \u00a0") or None
        if key.endswith("!") and clean(terms.get(key[:-1], "")):  # written without the shout: "free games awarded"
            return clean(terms[key[:-1]])
    return None

def main(folder):
    rows, missing = [], {}
    for lang in LANGS:
        path = os.path.join(folder, f"en_to_{FILE_CODE.get(lang, lang)}_dictionary.json")
        terms = json.load(open(path, encoding="utf-8")).get("dictionary", {}) if os.path.exists(path) else {}
        terms = {clean(k).lower(): v for k, v in terms.items() if isinstance(v, str)}
        for en in ENGLISH:
            word = lookup(terms, en)
            if word is None:
                missing.setdefault(en, []).append(lang)
                continue
            rows.append(f"{en}\t{lang}\t{word}")
    block = "\n".join(rows).replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    src_path = os.path.join(os.path.dirname(__file__), "..", "..", "NavigatorCore.swift")
    src = open(src_path, encoding="utf-8").read()
    start, end = "    static let tsv = \"\"\"\n", "\n    \"\"\"\n    // ART WORDS END"
    i, j = src.index(start) + len(start), src.index(end)
    open(src_path, "w", encoding="utf-8").write(src[:i] + "\n".join("    " + r for r in block.split("\n")) + src[j:])
    print(f"{len(rows)} words written for {len(LANGS)} languages.")
    for en, langs in missing.items():
        print(f"missing  {en!r}: {'all' if len(langs) == len(LANGS) else ', '.join(langs)}")

if __name__ == "__main__":
    main(sys.argv[1])
