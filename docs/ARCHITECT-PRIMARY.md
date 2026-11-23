# プライマリ architect 実行手順書（Orca の対話セッション専用）

Orca で人間が対話的に操作するモデル（例: Gemini 4 Neon）向けの手順書です。
Antigravity の skill（`docs/antigravity/fable-architect-primary/`）、または GEMINI.md / AGENTS.md からこのファイルを参照させてください。
`FABLE_ADVISOR_HOME` にプラグインのディレクトリを設定します。以下の <HOME> は、`printenv FABLE_ADVISOR_HOME` で得た絶対パスです（変数のまま書かず、必ず絶対パスに置き換えて実行する）。

人間からタスクが渡されるのは最初の 1 回だけです。以降は最後まで自分で進めます。
下記で STOP と書かれた場合を除き、人間に確認を求めないでください。

コマンドは 1 つずつ、そのままの形で実行してください。`if` / `for` / サブシェル / `&&` / `;`
で包んだり連結したりしないでください。承認の許可ルールは、コマンドの先頭がスクリプトの
絶対パスで始まる形にしか一致しません。包んだり、`$VAR` や `~` を使ったりすると、毎回承認を求められます。

1. ターンの最初の操作として、何かを読む前に次を実行する:
   `<HOME>/scripts/fable-architect.py ack`
   （claim から 30 秒以内に実行しないと、タスクはフォールバックに移ります）
2. タスクを事実として記述し、ルーターで経路を決める:
   `echo '{"objective":"...","file_count":N,"verification_available":true}' | <HOME>/scripts/fable-route.py route`
3. `security_sensitive` / `schema_change` / `data_migration` / `irreversible` /
   `api_change` / `concurrency_sensitive` のいずれかが true なら STOP。
   `<HOME>/scripts/fable-architect.py done` を実行し、何が・なぜ止まったかを人間に伝える。
   これらは独立したレビューが必要で、そのレビュアーは自分では起動できない。
4. 5 部構成の spec（目的・ファイル・インターフェース・制約・検証）を書き、
   ルーターが返した `lane_args` を変更せずに、専用の worktree でレーンを実行する:
   `<HOME>/scripts/codex-lane.sh --spec <spec> --files "<f1,f2>" <lane_args>`
   続けて
   `<HOME>/scripts/codex-lane-apply.sh --worktree <wt> --repo <repo> --files "<f1,f2>" --remove`
   共有ツリーを自分で編集しない。共有ツリーで `git checkout --` を実行しない。
5. 各レーンの前と、大きな工程の前に `<HOME>/scripts/fable-architect.py beat` を実行する。
   10 分間 beat が途絶えると「消失（lost）」と見なされ、フォールバックが引き継ぐ。
6. レーンが失敗したら `prior_failures` を増やして再ルーティングする。
   codex の quota 切れ、または 2 回失敗した場合は STOP して人間に報告する
   （自動フェイルオーバーはしない）。
7. 終了時（または STOP 時）に `<HOME>/scripts/fable-architect.py done` を実行し、
   変更ファイル・検証結果・次に実行すべきコマンドを報告する。
   指示がない限り commit も push もしない。
