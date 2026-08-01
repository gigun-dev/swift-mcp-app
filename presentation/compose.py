#!/usr/bin/env python3
"""スライド PNG + デモ動画 + TTS 音声を 1本の 1920x1080 mp4 に合成する。

設計メモ(Why):
  - **各セグメントの長さは音声が決める。** 映像を音に合わせる(逆ではない)。
    ナレーションが途中で切れるのが一番みっともないので、尺の基準を音側に置く。
  - デモ映像は縦長(1206x2622)なので、白地の中央に置いてレターボックスする。
    16:9 に切り出す案は却下 — カードの上下が切れてデモの意味が消える。
  - デモは実測より短い尺に詰めるため **setpts で早送り**する。思考待ちを含む
    デモを等速で流す尺は無い。何が起きているかはナレーションが説明する。
  - 個別に mp4 を書き出してから concat する。1本の filter_complex で全部やる案は
    デバッグ不能になるので採らない(1セグメント失敗したらそこだけ作り直せる形にする)。
"""
import os, subprocess, sys, json

HOME = os.path.expanduser("~")
SL = f"{HOME}/tmp-sim/slides"
TTS = f"{HOME}/tmp-sim/tts"
SIM = f"{HOME}/tmp-sim"
OUT = f"{HOME}/tmp-sim/build"
os.makedirs(OUT, exist_ok=True)

# (種別, 素材, 音声id)  種別: slide | demo
PLAN = [
    ("slide", "s01.png", "01-title"),
    ("slide", "s02.png", "02-agenda"),
    ("slide", "s03.png", "03-made"),
    # サーバー追加の録画(demoD)が壊れたため、設定画面の静止画で代替。
    ("shot",  "s06-settings.png", "03b-addserver"),
    ("slide", "s04.png", "04-usage"),
    ("demo",  "rA1.mov", "d1-b1"),
    ("demo",  "rA2.mov", "d1-b2"),
    ("demo",  "rA3.mov", "d1-b3"),
    ("slide", "s05.png", "05-arch"),
    ("slide", "s06.png", "06-pain"),
    ("slide", "s07.png", "06-why"),
    ("slide", "s08.png", "07-caldav"),
    ("slide", "s09.png", "08-servers"),
    ("slide", "s10.png", "09-hard1"),
    ("slide", "s11.png", "10-hard2"),
    ("demo",  "demoB.mov", "d2"),
    ("slide", "s12.png", "11-next"),
    ("slide", "s13.png", "12-summary"),
    ("slide", "s14.png", "13-thanks"),
]

PAD = 1.0  # 各セグメント末尾に足す無音(間)。詰まりすぎを避けるため 0.5→1.0 へ


def dur(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "csv=p=0", path], capture_output=True, text=True)
    return float(r.stdout.strip())


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        print(" ".join(cmd)); print(p.stderr[-2000:]); sys.exit(1)


def main():
    parts = []
    total = 0.0
    for i, (kind, src, aid) in enumerate(PLAN):
        wav = f"{TTS}/{aid}.wav"
        d = dur(wav) + PAD
        # デモ映像は喋り終わったあとも数秒残す。カードが出た瞬間で黙って見せる時間が要る。
        if kind == "demo":
            d += 4.0
        out = f"{OUT}/{i:02d}-{aid}.mp4"
        if kind == "slide":
            run(["ffmpeg", "-y", "-loglevel", "error",
                 "-loop", "1", "-framerate", "30", "-i", f"{SL}/{src}",
                 "-i", wav,
                 "-filter_complex",
                 f"[0:v]scale=1920:1080,format=yuv420p,trim=duration={d},setpts=PTS-STARTPTS[v];"
                 f"[1:a]apad,atrim=duration={d},asetpts=PTS-STARTPTS[a]",
                 "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                 "-c:a", "aac", "-b:a", "128k", "-r", "30", out])
        elif kind == "shot":
            # 縦長のスクリーンショット。デモ映像と同じ見え方に揃える
            # (白余白だと端末画面と溶けるので淡いグレー + 外周の枠)。
            run(["ffmpeg", "-y", "-loglevel", "error",
                 "-loop", "1", "-framerate", "30", "-i", f"{SIM}/{src}",
                 "-i", wav,
                 "-filter_complex",
                 f"[0:v]scale=-2:1020,drawbox=x=0:y=0:w=iw:h=ih:color=0xCBD5E1:t=3,"
                 f"pad=1920:1080:(ow-iw)/2:(oh-ih)/2:0xE2E8F0,format=yuv420p,"
                 f"trim=duration={d},setpts=PTS-STARTPTS[v];"
                 f"[1:a]apad,atrim=duration={d},asetpts=PTS-STARTPTS[a]",
                 "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                 "-c:a", "aac", "-b:a", "128k", "-r", "30", out])
        else:
            vsrc = f"{SIM}/{src}"
            vd = dur(vsrc)
            speed = vd / d                      # 音声尺へ詰めるための早送り係数
            run(["ffmpeg", "-y", "-loglevel", "error",
                 "-i", vsrc, "-i", wav,
                 "-filter_complex",
                 # 端末画面は白が大半なので、余白を白にすると輪郭が消えて
                 # 「小さい画像が浮いている」ように見える。余白は淡いグレー(#e2e8f0)、
                 # 端末の外周に 1px の枠(#cbd5e1)を描いて境界を立てる。
                 f"[0:v]setpts=PTS/{speed:.5f},fps=30,scale=-2:1020,"
                 f"drawbox=x=0:y=0:w=iw:h=ih:color=0xCBD5E1:t=3,"
                 f"pad=1920:1080:(ow-iw)/2:(oh-ih)/2:0xE2E8F0,format=yuv420p,"
                 f"trim=duration={d},setpts=PTS-STARTPTS[v];"
                 f"[1:a]apad,atrim=duration={d},asetpts=PTS-STARTPTS[a]",
                 "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                 "-c:a", "aac", "-b:a", "128k", "-r", "30", out])
            print(f"  {aid}: demo {vd:.1f}s -> {d:.1f}s ({speed:.2f}x)")
        parts.append(out)
        total += d
        print(f"{i:02d} {aid}: {d:.1f}s (累計 {total:.1f}s)")

    lst = f"{OUT}/list.txt"
    with open(lst, "w") as f:
        for p in parts:
            f.write(f"file '{p}'\n")
    final = f"{HOME}/tmp-sim/1241444957.mp4"
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
         "-i", lst, "-c", "copy", final])
    print(f"\n=> {final}  {dur(final):.1f}s  {os.path.getsize(final)/1e6:.1f}MB")


if __name__ == "__main__":
    main()
