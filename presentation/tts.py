#!/usr/bin/env python3
"""presentation-plan.md §3 の確定稿を Gemini TTS で音声化する。

なぜスクリプトに原稿を直書きするか(Why not):
  §3 の Markdown をパースして取り出す案は、見出し記法や注記行の揺れに引きずられて
  壊れやすい。原稿は人間が推敲する対象で構造は安定しないので、
  「読み上げる文字列そのもの」をここに持つほうが事故が少ない。
  §3 を直したらここも直す — 二重管理は承知のうえで、確実さを取る。
"""
import base64, json, os, struct, subprocess, sys, urllib.request

MODEL = "gemini-3.1-flash-tts-preview"
VOICE = "Kore"
OUT = os.path.expanduser("~/tmp-sim/tts")

# (id, 想定秒, 読み上げテキスト)
SEGMENTS = [
    ("01-title", 12,
     "ひとりのカレンダーを、みんなの道具へ、というテーマで、"
     "AI と予定を立てる iOS アプリ MCPHost を開発しました。"),
    ("02-agenda", 4, "目次です。"),
    ("03-made", 15,
     "MCPHost は、チャットで AI と話すことで予定やタスクを管理してくれます。"
     "MCP は AI が外部のサービスを呼ぶための規格で、"
     "claude.ai のコネクタや ChatGPT のプラグインは MCP を抽象化したものです。"),
    ("03b-addserver", 8,
     "使いたいサービスは、URL を入れるだけで足せます。"
     "今回は、複数の MCP をつなぐと何ができるのかをお見せします。"),
    ("04-usage", 9,
     "実際に相談してみます。見てほしいのは、AI が何度もサーバーを呼びに行くところです。"),
    ("d1-b1", 13,
     "送ると、まず一度だけ、実行していいか聞かれます。"
     "そのあと、待ち時間を1つずつ調べていきます。"
     "行くのは明日なので、同じ曜日の過去2回が基準です。"),
    ("d1-b2", 16,
     "アトラクションごとに1日の形が違います。朝いちに山が来るもの、昼どきに落ちるもの。"
     "この谷を突き合わせて、待ち時間の少ない順番を組み立てます。"),
    ("d1-b3", 17,
     "移動と乗車のバッファを取って、時間ごとの予定になりました。"
     "朝いちにソアリン、次にタワー・オブ・テラー。混むものを先に押さえて、"
     "昼食の枠も入っています。専用のカレンダーを作って、そこに入れています。"),
    ("05-arch", 17,
     "ここからは仕組みの話です。作ったのはアプリだけではなくて、つなぎ先のサーバーも自分で書きました。"
     "接続している MCP は、カレンダーと、ディズニーの待ち時間の二つです。"),
    ("06-pain", 25,
     "カレンダーは、自分の予定を自分のために書く道具です。"
     "誰かと何かするときは、まず LINE や口頭で日程を決めて、決まってから各自が書き写す。"
     "調整はカレンダーの外で起きていて、相手が増えるほど重くなります。"
     "だんだん、手間を払ってもいい相手としか予定を立てなくなる。"),
    ("06-why", 26,
     "カレンダーのサーバーを自分で書いた理由です。"
     "iPhone の予定は端末の中に閉じていてサーバーからは見えないので、"
     "アプリを開いている間しか動かせないし、人と分け合うこともできません。"
     "予定がひとりのものから出られないのは、ここが理由です。"),
    ("07-caldav", 26,
     "とはいえ、自分のアプリでしか見えない予定は不便です。"
     "そこで CalDAV という、カレンダーの共通規格に合わせました。"
     "iPhone の設定からアカウントを追加で自分のサーバーを登録できて、"
     "アプリを消しても予定は純正カレンダーに残ります。"),
    ("08-servers", 18,
     "つないでいるサーバーは二つとも自分で書きました。"
     "予定とタスクを持つほうと、ディズニーの待ち時間を返すほうです。"
     "さっきの相談は、この二つをまたいで解いていました。"),
    ("09-hard1", 29,
     "いちばん苦労したのは、チャットの中に出るカードの作り方です。"
     "仕組み自体が新しくて、どう作るのが正解かまだ決まっていません。"
     "どこまで出すか。どこで入力するか。いつの状態を映すか。"
     "仕様にもホストに任せると書いてある部分が多くて、動かしてみるまで分かりませんでした。"),
    ("10-hard2", 21,
     "中でも時間を使ったのが、追加をどこで打たせるかです。"
     "全画面のフォームに切り替える方式を二回作って二回とも戻しました。"
     "画面が切り替わるとキーボードが閉じてしまう、と実機で分かったからです。"),
    ("d2", 21,
     "こちらはタスクの一覧です。予定だけでなく、リマインダーも同じアプリで扱えます。"
     "カードの中に、その場で入力する行が出ます。"
     "画面を切り替えないので、キーボードが閉じません。AI に頼まずに、自分で足せます。"),
    ("11-next", 22,
     "いまは自分ひとりのカレンダーですが、次は人と使えるようにしたいです。"
     "カレンダーごと分け合えれば、相手の空きを見て提案できる。"
     "予定に人を招待できれば、いつ空いてる、を聞き合わなくてよくなります。"
     "どちらも CalDAV に元からある仕組みなので、載せる場所はもうあります。"),
    ("12-summary", 19,
     "複数の MCP をまたぐと、待ち時間を調べて予定を立てる、が一つの会話で完結します。"
     "そのためにサーバー側を共通規格に合わせたので、この予定は最初からひとりのものではありません。"),
    ("13-thanks", 3, "ありがとうございました。"),
]


def pcm_to_wav(pcm: bytes, rate=24000, ch=1, bits=16) -> bytes:
    """Gemini TTS は生 PCM を返す。ffmpeg へ渡すためヘッダを付ける。"""
    ba = ch * bits // 8
    hdr = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, ch, rate, rate * ba, ba, bits) + b"data" + struct.pack("<I", len(pcm))
    return hdr + pcm


def synth(key: str, text: str) -> bytes:
    body = {
        "contents": [{"parts": [{"text": text}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": VOICE}}},
        },
    }
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent?key={key}",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        d = json.load(r)
    part = d["candidates"][0]["content"]["parts"][0]
    return base64.b64decode(part["inlineData"]["data"])


def main():
    env = os.path.expanduser("~/ghq/github.com/gigun-dev/swift-mcp-app/.env")
    key = ""
    for line in open(env, encoding="utf-8"):
        if line.startswith("GEMINI_API_KEY="):
            key = line.split("=", 1)[1].strip().strip('"')
    if not key:
        sys.exit("GEMINI_API_KEY not found")
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1:] or None
    for sid, target, text in SEGMENTS:
        if only and sid not in only:
            continue
        wav = os.path.join(OUT, f"{sid}.wav")
        if os.path.exists(wav) and os.path.getsize(wav) > 1000:
            print(f"skip {sid}")
            continue
        pcm = synth(key, text)
        open(wav, "wb").write(pcm_to_wav(pcm))
        dur = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav],
            capture_output=True, text=True).stdout.strip()
        print(f"{sid}: {float(dur):.1f}s (想定 {target}s) {len(text)}字")


if __name__ == "__main__":
    main()
