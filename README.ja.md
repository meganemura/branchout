# branchout

English: [README.md](README.md).

branchout は、1 つの Ruby メソッドを具体入力で実行し、その入力が通らなかった分岐の腕を表示する。

テストを足しているエージェントは、腕が未達であることまではカバレッジで分かる。どの比較で外れたか、どの入力が決定のいちばん近くまで届いたかは分からない。branchout はそのフロンティアを、条件と、腕を選ぶ向きと、決定に届いた最も近い入力とともに出す。エージェントは入力を足して同じコマンドを再実行する。branchout は入力ファイルを書き換えない。探索が終わると、発見した戻り値または例外を固定する minitest か RSpec を書く。

方法はコンコリックテスト（[DART](https://doi.org/10.1145/1065010.1065036)、[CUTE](https://doi.org/10.1145/1094811.1094816)）と、[ConcoLLMic](https://concollmic.github.io/) のような LLM が導くコンコリックに沿う。branchout はコンコリックテストに着想を得ているが、記号制約は解かない。次の入力は、エージェントが分岐フロンティアから提案する。

## 使い方

リポジトリのルートで実行する。種ファイルの入力は `[0]` の 1 件である。

```sh
ruby bin/branchout explore examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.seed.json \
  --strategy inputs \
  --random 0 \
  --seed 1
```

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

`cond: x == 114514` の `sense: cond-true` が、`[0]` では通らなかった腕である。`[114514]` を足して同じコマンドを再実行する。`examples/inputs/magic_value.json` がそのファイルで、`arms_covered: 2`、`FRONTIER` は `(none)` になる。

`ENTRY` は `Const.method` か `Const#method`。
`Const#method` では、入力ごとに `Const.new` で新しいレシーバーを作る。
`initialize` が引数を取るときは、各入力の `new` に入力と同じ形で書く。
`{"args": [5], "new": [10]}` は `Const.new(10).method(5)` を呼ぶ。
`--entry ENTRY` は位置引数の代わりになる。

探索中は `--strategy inputs --random 0` とし、`--seed` は固定する。新しく覆われた腕は、足した入力だけから来る。探索手順は [skills/branchout/SKILL.md](skills/branchout/SKILL.md) にある。

| フラグ | 既定 | 意味 |
| --- | --- | --- |
| `--inputs PATH` | なし | 入力の JSON ファイル |
| `--require PATH` | なし | ターゲットより先に PATH を読み込む。ライブラリの残りが要るターゲットに使う。繰り返し指定できる。出力するテストも同じファイルを読み込む |
| `--seed N` | `0` | 乱数の種 |
| `--random N` | `16` | ランダム標本の個数 |
| `--mutate-cap N` | `256` | リテラル変異の予算 |
| `--strategy LIST` | `inputs,mutate,random` | 戦略をカンマ区切りで、下の表の順に実行する |
| `--timeout SEC` | `1` | 入力 1 件の制限時間。0 より大きいこと |
| `--json` | オフ | テキストの代わりに JSON を標準出力へ出す |
| `--json-out PATH` | | JSON レポートを書く |
| `--md-out PATH` | | テキストレポートを Markdown で書く |
| `--emit-tests PATH` | | 特徴づけテストを書く。`explore` のみ |
| `--format NAME` | `minitest` | `minitest` か `rspec`。`--emit-tests` が要る。省くと、パスが `_spec.rb` で終わるときだけ RSpec |
| `--entry ENTRY` | 位置引数 | `Const.method` か `Const#method` |

| 戦略 | 実行するもの |
| --- | --- |
| `inputs` | 入力ファイルの各エントリ。canonical JSON が同じものは捨てる |
| `mutate` | ソースのリテラルを各引数スロットへ入れる。整数には `0`、`1`、`-1`、リテラル±1 も含む。浮動小数には `0.0`、`1.0`、`-1.0`、±1 も含む。文字列には `""`、`"a"`、末尾 1 文字を落としたリテラル、リテラルに `"1"` を足したものも含む。先頭 2 つの位置引数が数値のときは、そのスロットの直積も作り、`--mutate-cap` で切る。文字列リテラルは連結しない |
| `random` | 種つきの Park-Miller。整数は -3..12。文字列は長さ 0..3、文字は `abc01.-` |

```sh
ruby bin/branchout baselines examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.json \
  --seed 1 --random 40
```

`baselines` は `random`、`mutate`、`agent`（入力ファイルだけ）を別々の行で実行する。random と mutate の行は入力ファイルを実行しない。この対象では、`random` が 15 件を実行して 2 腕のうち 1 腕、`mutate` が 6 件で両腕、`agent` が 2 件で両腕を覆う。

入力ファイルは種 1 件から始める。

```json
{
  "inputs": [
    {"args": [0]}
  ]
}
```

エントリは配列だけでもよい。キーワードは `kwargs` に、コンストラクタ引数は `new` に書く。型推論が違うときは、`"types"` に位置引数 1 つにつき `int`、`float`、`string`、`array`、`hash` のいずれかを置く。`meta` のような他のトップレベルキーは無視する。エントリは末尾へ足す。消したり並べ替えたりしない。

```sh
ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb \
  --format rspec
```

この実行は 4 腕のうち 4 腕を覆い、`[24,12]` で `ZeroDivisionError`（`divided by 0`）を記録する。出力ファイルは戻り値、または例外クラスとメッセージを固定する。`Set` や `Struct` のように Ruby のリテラルで書けない戻り値は、クラスだけを固定する。minitest のパスは `--format minitest` で、`ruby` で実行する。RSpec には `rspec` gem が要る。

## フロンティアの作り方

`--require` のファイルと対象ファイルは `Coverage.setup(lines: true, branches: true)` のあとで読み、ロード時のカウントは捨てる。入力ごとに coverage を resume し、メソッドを呼び、suspend して `Coverage.result` を読む。残すのは入口メソッドと、同じファイル内で裸呼び出しまたは `self.` から届く callee だけである。

腕の id は Coverage の分岐キーから作る `kind@行:列/arm@行:列` である。列は 0 始まり。`cond` は Prism の述語で、`when` または `in` の腕ではその行である。位置が一致しないときはソースの行を使う。

フロンティアはカウントが 0 の腕である。`parent: reached` は、どれかの入力がその決定を実行したことを意味する。`nearest` は、そこに届いた入力のうち、通った腕が最も少なく、次に重み（数の絶対値に、文字列とコンテナの長さを足したもの）が最も小さく、次に canonical JSON が最も小さいものである。`path` は、その入力が通った腕のソート済み集合である。Coverage は順序を記録しない。ループ回数が 1 を超えると `*回数` を付ける。

`sense` は腕を選ぶ向きである。`cond-true`（`if` の then、`unless` の else）、`cond-false`（`if` の else、`unless` の then）、`arm-matched`（その `when` または `in`）、`arm-else`、`body-entered`（`while` または `until` の本体）、`receiver-present`、`receiver-nil`（`&.`）。

例外は腕のカバーとは別に出す。カバー済みの腕でも例外は起きる。同じ入力、同じフラグ、同じ CRuby なら標準出力は同じバイト列になる。レポートに時刻はない。パスは作業ディレクトリからの相対パスである。

## インストール

Ruby 3.3 以降。探索に使うのは標準ライブラリの Coverage、Prism、json である。このチェックアウトでは `ruby bin/branchout` を実行するか、`bin` を `PATH` に置く。出した minitest は `ruby` で実行する。出した RSpec には `rspec` gem が要る。

[branchout スキル](skills/branchout/SKILL.md)（英語）は [`skills` CLI](https://github.com/vercel-labs/skills)（Node.js 22.20 以降）で入れる。このリポジトリは private なので、GitHub へのアクセスが要る。

```sh
npx skills add meganemura/branchout
```

```sh
npx skills add meganemura/branchout --skill branchout
```

```sh
npx skills add meganemura/branchout -g
```

```sh
npx skills add meganemura/branchout -a cursor
```

`--skill` はこのスキルだけ、`-g` は全プロジェクト向け、`-a` は対象エージェントを指定する。

コピーまたはシンボリックリンクでも入れられる。

```sh
mkdir -p .agents/skills
ln -s /path/to/branchout/skills/branchout .agents/skills/branchout
```

`.claude/skills/` と `.cursor/skills/` でも同じ。

## 限界

- 対象は実際に実行される。対象の標準出力と標準エラーは捨てる。ファイル、グローバル、ネットワークはサンドボックスしない。
- 時刻、乱数、I/O に依存するメソッドは、同じ入力でもレポートが揃わない。
- 経路は腕の集合であり、順序ではない。`&&` と `||` は腕にならない。`while` と `until` が記録するのは本体の腕で、条件は実行されたが本体に入らなかったことは行カウントで補う。
- 修飾子の `unless` は then と else が同じ位置になることがある。id の腕名で区別する。
- 同じファイルの裸呼び出しと `self.` 以外は追わない。
- `Timeout.timeout` はすべてのブロックを止められない。タイムアウトのバックトレースに対象行が無いとき、`loc` はメソッド定義行になる。
- 充足できない条件はフロンティアに残る。`examples/arithmetic.rb` の `x == 114514 && x == 0` がそれである。
- 上のランダムと変異の範囲は、意図して狭い。
- Coverage はプロセス全体で 1 系統である。CLI は別プロセスで実行する。

## 開発

次のコマンドはソースのチェックアウト用である。

```sh
bundle install
ruby test/run_all.rb
bundle exec rspec spec/generated
```

`test/run_all.rb` は `test/test_*.rb` と `test/generated/*_test.rb` を読み込む。`spec/generated/` は `examples/` から出した RSpec である。Coverage はプロセス全体で 1 系統なので、CLI のテストは `bin/branchout` を子プロセスで起動する。

## ライセンス

ライセンスはまだ決めていない。
