---
name: fable-architect-primary
description: Orca で人間からタスクを受けたら最初に必ず使う。fable-advisor のプライマリ architect として、ack → ルーティング → codex レーン実行 → 適用 → done までを自走する手順。
---

# fable-architect-primary

Orca の対話セッションでタスクを受けたら、次の順に進める。

1. `printenv FABLE_ADVISOR_HOME` を 1 回だけ実行し、出力された絶対パスを <HOME> とする。
2. 次を実行する（何かを読む前に。30 秒以内に実行しないとフォールバックに移る）:
   `<HOME>/scripts/fable-architect.py ack`
   `ack ok` と出れば成功。出力が無い、または失敗なら、人間に伝えて止まる。
3. 続きは `<HOME>/docs/ARCHITECT-PRIMARY.md` を読み、その内容に従って最後まで自走する。

コマンドの実行ルール（許可ルールとの一致のため）:
- コマンドは <HOME> を実際の絶対パスに置き換えて書く。`$FABLE_ADVISOR_HOME` のような変数や
  `~` を実行ファイルの位置に使わない（展開が必要なコマンドは許可ルールに一致しない）。
- 各コマンドは単独で、そのままの形で実行する。`if` / `for` / サブシェル / `&&` / `;` で
  包んだり連結したりしない。
