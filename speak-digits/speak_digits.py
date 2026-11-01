#!/usr/bin/env python3
"""Listen on the microphone for a spoken 6-digit number and print it, fully offline."""

import argparse
import json
from pathlib import Path
import queue
import sys

import sounddevice as sd
from vosk import KaldiRecognizer, Model, SetLogLevel

MODEL_DIR = Path(__file__).resolve().parent / "model"
SAMPLE_RATE = 16_000
BLOCK = 800  # 50ms of audio per chunk keeps latency low
DIGITS = {
    "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
}
REPEATS = {"double": 2, "triple": 3}
# Restricting the vocabulary makes recognition both faster and far more accurate.
GRAMMAR = json.dumps([*DIGITS, *REPEATS, "[unk]"])


def to_digits(text):
    out, repeat = [], 1
    for word in text.split():
        if word in REPEATS:
            repeat = REPEATS[word]
        elif word in DIGITS:
            out.append(DIGITS[word] * repeat)
            repeat = 1
    return "".join(out)


def listen(length, timeout):
    SetLogLevel(-1)
    rec = KaldiRecognizer(Model(str(MODEL_DIR)), SAMPLE_RATE, GRAMMAR)
    audio = queue.Queue()

    def callback(data, frames, time, status):
        audio.put(bytes(data))

    done, last_partial = "", None
    with sd.RawInputStream(samplerate=SAMPLE_RATE, blocksize=BLOCK, dtype="int16",
                           channels=1, callback=callback, latency="low"):
        print(f"Say the {length}-digit number…", file=sys.stderr, flush=True)
        for _ in range(int(timeout * SAMPLE_RATE / BLOCK)):
            if rec.AcceptWaveform(audio.get()):
                done += to_digits(json.loads(rec.Result())["text"])
                current = done
            else:
                current = done + to_digits(json.loads(rec.PartialResult())["partial"])
                # Finish without waiting for trailing silence once a full-length
                # partial result has held steady for one extra chunk.
                if len(current) >= length and current == last_partial:
                    return current[:length]
                last_partial = current
            if len(done) >= length:
                return done[:length]
            print(f"\r{current:<{length}}", end="", file=sys.stderr, flush=True)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-n", "--length", type=int, default=6, help="number of digits (default 6)")
    parser.add_argument("-t", "--timeout", type=float, default=15, help="seconds to listen (default 15)")
    args = parser.parse_args()

    if not MODEL_DIR.is_dir():
        sys.exit(f"Speech model missing at {MODEL_DIR}; run setup.sh first")
    result = listen(args.length, args.timeout)
    print("\r", end="", file=sys.stderr)
    if result is None:
        sys.exit("Timed out without hearing a full number")
    print(result)


if __name__ == "__main__":
    main()
