# branchout

English: [README.md](README.md).

カバレッジに導かれる、エージェント駆動の入力探索。concolic execution に着想を得ているが、ツールの中では記号制約を集めず、解かない。

concolic execution は具体実行と同時に経路条件を記録し、まだ通っていない枝をソルバに解かせる。branchout がやるのはその前半の観測だけである。対象メソッドを具体入力で実行し、Coverage の分岐腕のうち未カバーのものを短いフロンティアとして出す。次の入力を提案するのは、その出力を読む人間かコーディングエージェントで、ツールの外にいる。SMT も LLM も呼ばない。

実行に gem は要らない。Coverage、Prism、json、minitest は処理系に付いているものを使う。出した RSpec を走らせるときだけ `rspec` が要る。開発用の Gemfile では minitest と rspec を dev dependency にしている。Ruby 3.3 以降のその API を想定し、Ruby 3.4.12 と Ruby 4.0.9 で `ruby test/run_all.rb` と `bundle exec rspec spec/generated` が通ること、デモの件数とカバー数が両者で一致することを確認した。3.3 そのものでは実行していない。

## 設計

1. 対象ファイルを `Coverage.setup(lines: true, branches: true)` のあとで `require` する。ロード時のカウントは捨て、入力ごとに `resume` / 実行 / `suspend` / `Coverage.result(stop: false, clear: true)` する。対象メソッドと、同じファイル内で裸呼び出しまたは `self.` から到達するメソッドの行だけを見る。
2. 腕の id は `if@行:列/then@行:列` のように、Coverage の分岐キーの位置から作る。列は 0 始まり。
3. 条件の文字列は Prism の述語、または `when` の行。位置が一致しないときはその行のソースに戻す。
4. 1 回の実行の経路は、カウントが正の腕のソート済み集合。ループは `*回数` になる。通った順は Coverage が返さない。
5. フロンティアはカウント 0 の腕。親の決定をどれかの入力が実行していれば `parent: reached` と、そこに到達した最も単純な入力（通った腕が少ない、数の絶対値が小さい、canonical JSON が小さい）を出す。
6. リテラル変異は、そのスライスに出てくる整数・浮動小数・文字列を集め、各引数スロットへ入れる。整数は 0, 1, -1 とリテラル±1 も入れる。数値 2 引数だけ直積を足し、`--mutate-cap` で切る。文字列リテラル同士は連結しない。
7. ランダムは純 Ruby の Park-Miller。整数は -3..12、文字列は長さ 0..3、文字は `abc01.-`。種は `--seed`。
8. 例外は捕捉して所見にする。ゼロ除算のような、腕の中に隠れている故障はカバー数とは別に残る。
9. 発見した入力（inputs に書いたもの、腕の証人、例外を起こした入力）から特徴づけテストを出す。エミッタは `lib/branchout/emitters/` に分かれており、minitest と RSpec を選べる。コアはどちらも require しない。

出力に時刻は入れない。同じ入力、同じフラグ、同じ CRuby なら標準出力はバイト一致する。

## 実行

```sh
ruby bin/branchout explore examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.json \
  --strategy inputs --random 0 --seed 1

ruby bin/branchout baselines examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.json \
  --seed 1 --random 40

ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb

bundle install
bundle exec rspec spec/generated

ruby test/run_all.rb
```

`ENTRY` は `Const.method` か `Const#method`。後者は `new` の必須引数が 0 であること。

主なフラグは `--inputs`、`--seed`、`--random`、`--mutate-cap`、`--strategy inputs,mutate,random`、`--timeout`、`--json`、`--json-out`、`--md-out`、`--emit-tests`、`--format minitest|rspec`。`--format` を省くと、出力パスが `_spec.rb` で終わるときだけ RSpec、それ以外は minitest。

inputs の形:

```json
{
  "types": ["int"],
  "inputs": [
    {"args": [0]},
    [114514]
  ]
}
```

`types` を省くと、メソッド本体の使われ方から int / float / string / array / hash を推定する。

## エージェントのループ

手順の本体は [AGENTS.md](AGENTS.md)。探索中は `--strategy inputs --random 0 --seed 1` に固定する。エージェントは `parent: reached` の腕ごとに、`nearest` を 1 箇所だけ変えた入力を inputs.json の末尾へ足して、同じコマンドを再実行する。ツールはファイルを書き換えない。

デモではその手順をこのまま実行した。モデル API は使っていない。ツールに LLM バックエンドはない。

魔法数のラウンド 0（`examples/inputs/magic_value.seed.json`）:

```
branchout explore
target: examples/magic_value.rb
entry: MagicValue.classify
seed: 1
strategies: inputs
random: 0
mutate_cap: 256
timeout: 1
inputs_ran: 1
mutate_ran: 0
random_ran: 0
executions: 1
arms_covered: 1
arms_total: 2
exceptions: 0

COVERED
id: if@5:4/else@8:6
loc: examples/magic_value.rb:8:6
cond: x == 114514
sense: cond-false
input: [0]

FRONTIER
id: if@5:4/then@6:6
loc: examples/magic_value.rb:6:6
cond: x == 114514
sense: cond-true
parent: reached
nearest: [0]
path: if@5:4/else@8:6

EXCEPTIONS
(none)
```

`sense: cond-true` なので `[114514]` を足す。ラウンド 1 で `arms_covered: 2`、`FRONTIER` は `(none)`。

他のデモで足した入力と、残った腕:

| デモ | ラウンド | 最終入力 | 結果 |
| --- | --- | --- | --- |
| `MagicValue.classify` | 1 | `[0]`、`[114514]` | 2/2 |
| `Arithmetic.classify` | 3 | `[0,0,0]`、`[138,0,0]`、`[114514,0,0]`、`[138,143,0]`、`[138,143,7]` | 7/8。`x == 114514 && x == 0` の then は試行後も未カバー |
| `VersionParser.parse` | 3 | `""`、`"0"`、`"-"`、`"0.0.0"`、`"0-rc1"`、`"0-beta1"` | 12/12 |
| `HiddenBug.scale` | 2 | `[0,0]`、`[11,11]`、`[100,11]`、`[24,12]` | 4/4。`[24,12]` で `ZeroDivisionError` |

算術の各ラウンドは、合同式 `(x * 3 + 7) % 1000 == 421`（x = 138）、次に `y == x + 5`（y = 143）、次に `z == 7`。バージョンパーサは、空でない文字列、ハイフンと 3 成分の数、最後に `rc` と `beta`。隠れたバグは、両方を 10 より大きくしてから、`a - b * 2 >= 50` と `a == b * 2`。

各ラウンドの標準出力は `reports/transcripts/` にある。

## ベースライン

`baselines` を `--seed 1 --random 40 --mutate-cap 256` で、最終 inputs を agent 列に使って測った。random と mutate はこの inputs を実行しない。executions が 40 より小さいのは、重複入力を捨てているため。

| 対象 | random | mutate | agent |
| --- | --- | --- | --- |
| magic_value（腕 2） | 15 実行、1 カバー、例外 0 | 6 実行、2 カバー、例外 0 | 2 実行、2 カバー、例外 0 |
| arithmetic（腕 8） | 40 実行、2 カバー、例外 0 | 256 実行、2 カバー、例外 0 | 5 実行、7 カバー、例外 0 |
| version_parser（腕 12） | 20 実行、8 カバー、例外 0 | 12 実行、8 カバー、例外 0 | 6 実行、12 カバー、例外 0 |
| hidden_bug（腕 4） | 37 実行、1 カバー、例外 0 | 196 実行、4 カバー、例外 0 | 4 実行、4 カバー、例外 1 |

magic の定数 `114514` はソースにそのままあるので変異が両方の腕を覆う。ランダムの範囲には入らない。

arithmetic のランダムと変異が覆ったのは、合同式が偽のときの 2 腕だけ。`138` はリテラルでも ±1 でもない。

version_parser のランダムと変異は、空、非リリース、ハイフンありでタグが `rc` でも `beta` でもない経路までで止まった。足りない 4 腕は `tag.start_with?("rc")` の then、`tag.start_with?("beta")` の then、`release?(text)` の then、`parts.length == 3` が真のとき。

hidden_bug の変異は直積で 4 腕すべてを通した。`a == 2 * b` かつ両方とも 10 より大きい組はプールに無く、例外は 0。エージェントの 4 入力目だけが `divided by 0` を起こす。カバーが満杯でも故障は別、という結果。

生の表は `reports/*_baselines.txt`。フロンティアは `reports/*.txt` と `reports/*.json`、`reports/*.md`。

## 特徴づけテスト

`test/generated/` は minitest、`spec/generated/` は RSpec。どちらも最終 inputs から出し、戻り値、または例外クラスとメッセージを固定する。

```sh
ruby test/generated/hidden_bug_test.rb
bundle exec rspec spec/generated/hidden_bug_spec.rb
```

RSpec 側は `expect(HiddenBug.scale(0, 0)).to eq(:out_of_range)` と `expect { HiddenBug.scale(24, 12) }.to raise_error(ZeroDivisionError, "divided by 0")` の形になる。

`HiddenBug.scale(24, 12)` は `ZeroDivisionError` と `"divided by 0"`。`HiddenBug.scale(11, 11)` は `-91`（`1000 / -11`）。

## 決定性

id、フロンティア、例外、ベースラインの行はソートされる。JSON のキー順は出力側で固定し、文字列は `\uXXXX` に揃える。入力の `-0.0` は `0.0` にする。コンパクト出力に時刻や絶対パスは出さない。作業ディレクトリからの相対パスを使う。

## 限界

- 対象は本当に実行される。標準出力と標準エラーは捨てるが、ファイル、グローバル、ネットワークはそのまま起きる。サンドボックスではない。
- 時刻、乱数、I/O に依存するメソッドでは、同じ入力でもレポートが揃わない。
- 経路は腕の集合であり、順序ではない。経路爆発は「未カバーの腕」に潰して避けている代わりに、同じ腕を別の順で通る差は見えない。`*回数` はループの回数だけを残す。
- Coverage の分岐は `if` / `unless` / `case` / `while` / `until` / `&.` とパターンの `in`。`&&` と `||` は腕にならない。`while` は本体の腕だけで、入らなかったことは行カウントで補う。修飾子の `unless` は then と else が同じ位置になることがあり、id の腕名で区別する。
- 同じファイルの裸呼び出し以外（`send`、他ファイルの callee）は追わない。
- `Timeout.timeout` は全ブロックを止められない。タイムアウトのバックトレースに対象行が無いときはメソッド定義行を loc にする。
- 充足不能な条件はフロンティアに残る。arithmetic の `x == 114514 && x == 0` がそれ。
- ランダムと変異の範囲は上の通り狭い。広くすると偶然当たることが増え、表の意味がぼやける。
- プロセス全体で Coverage は 1 系統。テストは CLI を別プロセスで起動している。

## 次の一歩

発見した具体値は、プロパティテストの種になる。gem `hegeltest`（Hegel の Ruby バインディング）は `Hegel.test` で値を引き、失敗を `reproduce_failure` と example database（`database_key`）で再生する。branchout の inputs.json を、そのデータベースの初期失敗として入れるか、プロパティの先頭で同じ引数を一度ずつ評価するアダプタに渡す。Hypothesis 系の crosshair がソルバで例を寄せるのと同じ位置を、ここではフロンティアとエージェントの提案が担う。

Just-in-Time catching test にするなら、同じ入力を base と head で実行し、戻り値か例外が割れたものだけを残す。shadow symbolic execution が変更の影響する経路へ入力を寄せる代わりに、未カバー腕と、そこへ到達した nearest を種にする。

対象を絞るには SimpleCov のテスト単位カバレッジを使う。`SimpleCov.start { track_tests }` のあと、`simplecov affected --base main` が挙げるテストと、そのテストが触ったメソッドに `explore` を限る。変更に無関係なメソッドの腕をエージェントに読ませないため。

参照した流れは、ConcoLLMic（LLM がソルバを手伝う concolic）、AutoBug、リテラルを比較オペランドとして使うコンコリックの解説（[zenn.dev/termoshtt/articles/concolic-execution](https://zenn.dev/termoshtt/articles/concolic-execution)）の「ソルバを外に出す」部分。ソルバの位置に、このリポジトリではツールの外のエージェントを置いている。
