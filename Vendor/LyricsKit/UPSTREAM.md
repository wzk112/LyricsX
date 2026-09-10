# LyricsKit

Source: https://github.com/MxIris-LyricsX-Project/LyricsKit

Base revision: `bb255842eb8fe48880e15c23c0a7704599dd3504`.
The original license is retained in `LICENSE`.

This source snapshot makes the provider fixes reproducible in release builds:
completion-order delivery with bounded downloads and cancellation; larger search
pages; NetEase search fallback; the Kugou HTTPS song-search endpoint; and deterministic QQ candidate deduplication. Original parsers and
LRCX serialization are preserved. Local compatibility tests live in the root
project's `Tests/LyricsXServicesTests` directory.

LRCLIB nullable records and plain lyrics are handled by the application adapter
in `Sources/LyricsXServices/LRCLIBSearch.swift`. NetEase YRC translation merging
and conservative nearby-timestamp alignment are also patched in this snapshot.
