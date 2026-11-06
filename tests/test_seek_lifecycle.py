#!/usr/bin/env python3
"""Test actual ClipPlayer play/stop methods using a deterministic player and main queue.

SWIFT=/path/to/swift python3 -I tests/test_seek_lifecycle.py [Sources/naiwa/Assets.swift]
This runs on Linux without AVFoundation; native macOS playback/CPU checks remain necessary.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "Sources/naiwa/Assets.swift"
text = source.read_text()
methods = []
for name in ("play", "stop"):
    match = re.search(r"^    func " + name + r"\(.*?^    \}", text, re.M | re.S)
    if not match:
        raise AssertionError(f"Missing ClipPlayer.{name}")
    methods.append(match.group())
generation = re.search(r"^    private var playbackGeneration:.*$", text, re.M)
harness = r'''
import Foundation
struct Time { static let zero = Time() }
final class Player {
    var seeks: [(Bool) -> Void] = []
    var plays = 0
    var playing = false
    func seek(to: Time, toleranceBefore: Time, toleranceAfter: Time, completionHandler: @escaping (Bool) -> Void) {
        seeks.append(completionHandler)
    }
    func play() { plays += 1; playing = true }
    func pause() { playing = false }
}
final class TestQueue {
    var pending: [() -> Void] = []
    func async(execute: @escaping () -> Void) { pending.append(execute) }
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}
// Model the main queue explicitly so a stop may race between completion arrival and queued execution.
struct DispatchQueue { static let main = TestQueue() }
final class ClipPlayer {
    let player = Player()
    private var onEnd: (() -> Void)?
'''
cases = r'''
}
// Current successful seek starts once.
let current = ClipPlayer()
current.play(onEnd: {})
current.player.seeks[0](true)
DispatchQueue.main.drain()
precondition(current.player.plays == 1 && current.player.playing)
// Cancelled seeks must never start the player.
let cancelled = ClipPlayer()
cancelled.play(onEnd: {})
cancelled.player.seeks[0](false)
DispatchQueue.main.drain()
precondition(cancelled.player.plays == 0, "Cancelled seek restarted playback")
// Both completion outcomes after a stop remain paused.
for finished in [true, false] {
    let stopped = ClipPlayer()
    stopped.play(onEnd: {})
    stopped.stop()
    stopped.player.seeks[0](finished)
    DispatchQueue.main.drain()
    precondition(stopped.player.plays == 0 && !stopped.player.playing, "Late seek restarted stopped playback")
}
// A completion received before stop but queued afterward must also be invalidated.
let queued = ClipPlayer()
queued.play(onEnd: {})
queued.player.seeks[0](true)
queued.stop()
DispatchQueue.main.drain()
precondition(!queued.player.playing, "Queued completion outlived stop")
// Restarting does not revalidate an earlier playback attempt.
let restarted = ClipPlayer()
restarted.play(onEnd: {})
restarted.stop()
restarted.play(onEnd: {})
restarted.player.seeks[0](true)
DispatchQueue.main.drain()
precondition(restarted.player.plays == 0, "Previous generation started the new attempt")
restarted.player.seeks[1](true)
DispatchQueue.main.drain()
precondition(restarted.player.plays == 1)
// Consecutive plays without stop also supersede the first attempt.
let replaced = ClipPlayer()
replaced.play(onEnd: {})
replaced.play(onEnd: {})
replaced.player.seeks[0](true)
DispatchQueue.main.drain()
precondition(replaced.player.plays == 0)
replaced.player.seeks[1](true)
DispatchQueue.main.drain()
precondition(replaced.player.plays == 1)
print("Seek lifecycle passed: success, cancellation, stopped/queued callbacks, restart, consecutive plays")
'''
with tempfile.TemporaryDirectory(prefix="naiwa-seek-test-") as temporary:
    script = Path(temporary) / "main.swift"
    script.write_text(harness + (generation.group() if generation else "") + "\n" + "\n".join(methods) + cases)
    subprocess.run([os.environ.get("SWIFT", "swift"), str(script)], check=True, timeout=60)
