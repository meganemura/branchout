# branchout

English: [README.md](README.md).

branchout は、Ruby のメソッドを多くの入力で実行し、どの入力も通らなかった分岐の腕を示し、メソッドの今のふるまいを固定する RSpec か minitest の例を書く。

## Rails アプリでのクイックスタート

この手順では、RSpec とファクトリでテストしている Rails アプリに branchout を足し、モデルのメソッドを 1 つ探索する。
探索はスイートの中で、アプリを起動し、テスト用のデータベースを使って動く。

最初の対象には、`if`、`unless`、`case` の腕が 2 個から 5 個あり、値を返すモデルのメソッドを選ぶ。
そのモデルにはファクトリがあるとよい。
最近のコミットが変えたメソッドから始めるのもよい。
`git log -5 --oneline -- app/models` がそのコミットを並べる。

1. Gemfile の test グループに gem を足し、インストールする。

```ruby
group :test do
  gem "branchout", require: false
end
```

```sh
bundle install
```

2. メソッドを探索するスペックファイルを 1 つ書く。
`Loan`、`approve`、ファクトリの呼び出し、引数、2 つのファイル名を自分のものに置き換える。
レシーバと各引数は、文字列に入れた Ruby のソースである。

```ruby
# spec/models/loan_explore_spec.rb
require "branchout/coverage" if ENV["BRANCHOUT"]
require "rails_helper"
require "branchout"

RSpec.describe Loan, type: :model do
  it "explores approve", if: ENV["BRANCHOUT"] do
    clerk = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "create(:loan)"}, args: [clerk]}
    ])
  end
end
```

1 行目は、`rails_helper` がアプリを起動する前にカバレッジを始める。
そのため branchout はモデルのファイルの腕を数えられる。
`BRANCHOUT` がなければこの例は飛ばされるので、ファイルはスイートに置いたままにできる。
各入力はロールバックされるセーブポイントの中で動くので、ほかの入力が書いた行は見えない。

3. 実行する。

```sh
BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb
```

### 出力の例

次の出力は小さなサンプルアプリのものである。
メソッドは次のとおり。

```ruby
  def approve(officer)
    return :already if state == "approved"
    return :over_limit if borrower.approved_cents + amount_cents > borrower.limit_cents
    return :needs_senior if amount_cents > 10_000 && !officer.fetch(:senior)

    update!(state: "approved", approved_by: officer.fetch(:name))
    :approved
  end
```

```text
branchout explore app/models/loan.rb Loan#approve
covered: 3 of 6 arms by 1 input
raised: none
tests: spec/models/loan_approve_spec.rb

FRONTIER (add an input like the nearest above each arm, changed as the arm says)
nearest: {"args":[{"ruby":"{name: 'Grace', senior: false}"}],"receiver":{"ruby":"create(:loan)"}}
app/models/loan.rb:7:4 makes `state == "approved"` true
app/models/loan.rb:8:4 makes `borrower.approved_cents + amount_cents > borrower.limit_cents` true
app/models/loan.rb:9:4 makes `amount_cents > 10_000 && !officer.fetch(:senior)` true

OPERATORS (coverage does not see which side ran; vary each left side)
app/models/loan.rb:9:50 && in `amount_cents > 10_000 && !officer.fetch(:senior)`

Pass verbose: true for every covered arm and the run settings.
.

Finished in 0.28375 seconds (files took 2.14 seconds to load)
1 example, 0 failures
```

1 件の入力が 6 個の腕のうち 3 個を通った。
`FRONTIER` の下の各行は、どの入力も通らなかった腕で、そのファイル、行、列と、腕を通るために入力がすべきことを言う。
`nearest` は最も近づいた入力なので、それを写して行の言うとおりに変える。
`OPERATORS` は、カバレッジが両辺を数えない `&&` を示す。
その左辺を真にする入力と偽にする入力を与える。
この実行は `spec/models/loan_approve_spec.rb` も書いた。
これは各入力が返した値を固定する。

### 次に、フロンティアを閉じる

`FRONTIER` のエントリごとに入力を 1 件足し、手順 3 をもう一度実行する。
サンプルアプリでは、借り手の限度額は 20,000 セントである。

```ruby
# spec/models/loan_explore_spec.rb
require "branchout/coverage" if ENV["BRANCHOUT"]
require "rails_helper"
require "branchout"

RSpec.describe Loan, type: :model do
  it "explores approve", if: ENV["BRANCHOUT"] do
    clerk = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "create(:loan)"}, args: [clerk]},
      {receiver: {ruby: "create(:loan, :approved)"}, args: [clerk]},
      {receiver: {ruby: "create(:loan, amount_cents: 25_000)"}, args: [clerk]},
      {receiver: {ruby: "create(:loan, amount_cents: 15_000)"}, args: [clerk]}
    ])
  end
end
```

```sh
BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb
```

```text
branchout explore app/models/loan.rb Loan#approve
covered: 6 of 6 arms by 4 inputs
raised: none
tests: spec/models/loan_approve_spec.rb

FRONTIER
(none)

OPERATORS (coverage does not see which side ran; vary each left side)
app/models/loan.rb:9:50 && in `amount_cents > 10_000 && !officer.fetch(:senior)`

Pass verbose: true for every covered arm and the run settings.
.

Finished in 0.35302 seconds (files took 0.98271 seconds to load)
1 example, 0 failures
```

これですべての腕を通った。
書き出したスペックは、`BRANCHOUT` なしで、ほかのスペックと同じように動く。

```sh
bundle exec rspec spec/models/loan_approve_spec.rb --format documentation
```

```text
Loan
  #approve
    with create(:loan)
      returns :approved
    with create(:loan, :approved)
      returns :already
    with create(:loan, amount_cents: 15_000)
      returns :needs_senior
    with create(:loan, amount_cents: 25_000)
      returns :over_limit

Finished in 0.04388 seconds (files took 0.93715 seconds to load)
4 examples, 0 failures
```

書き出したスペックをコミットする。
メソッドが返す値が変わると、このスペックは失敗する。
探索のスペックは次の回のために残しても、消してもよい。
コーディングエージェントも同じループを回す。
`FRONTIER` を読み、入力を足し、再実行する。
その手順は [skills/branchout/SKILL.md](skills/branchout/SKILL.md)（英語）にある。
`Branchout.explore` のすべてのオプションは [テストスイートの中で使う](#テストスイートの中で使う) にある。

## アプリなしで試す

CLI は、アプリなしで読み込めるメソッド（`lib/` の下のモジュールなど）を、そのファイルから探索する。

gem と、それが書くスペックを実行する RSpec を入れる。

```sh
gem install branchout rspec
```

空のフォルダに、分岐がいくつかあるメソッドを書く。

```sh
cat > shipping.rb <<'RUBY'
module Shipping
  def self.fee(weight, express: false)
    raise ArgumentError, "weight must be positive" unless weight.positive?

    base = weight <= 2 ? 5 : 5 + (weight - 2) * 2
    express ? base * 2 : base
  end
end
RUBY
```

探索して、スペックを書き出す。

```sh
branchout explore shipping.rb Shipping.fee --emit-tests shipping_spec.rb
```

```text
branchout explore shipping.rb Shipping.fee
covered: 5 of 6 arms by 13 inputs
raised: 3 inputs
tests: shipping_spec.rb

FRONTIER (add an input like the nearest above each arm, changed as the arm says)
nearest: [1]
shipping.rb:6:14 makes `express` true

EXCEPTIONS
ArgumentError at shipping.rb:3: weight must be positive
  inputs: [-1], [-2], [0]

Pass --verbose for every covered arm and the run settings.
```

branchout は、メソッド自身のリテラルとシード付きの標本から 13 件の入力を作って実行した。
それらは 6 本の腕のうち 5 本を通った。
`FRONTIER` は、どの入力も通らなかった腕である。
ここでは `express` が一度も真にならなかった。
`nearest` のような入力で、`express` を真にするものを足す。
`EXCEPTIONS` は、例外を出した入力の一覧である。
`--verbose` を付けると、通った各腕の入力も表示する。

書き出したスペックは、各戻り値と各例外を固定する。

```sh
cat shipping_spec.rb
```

```ruby
# frozen_string_literal: true

# Generated by branchout 0.1.0. Characterization specs for discovered inputs.
# target: shipping.rb
# entry: Shipping.fee

require_relative "./shipping.rb"

RSpec.describe Shipping do
  describe ".fee" do
    it "raises ArgumentError when weight is -1" do
      # covers:
      #   line 3: unless weight.positive? -> then
      expect { Shipping.fee(-1) }.to raise_error(ArgumentError, "weight must be positive")
    end

    it "raises ArgumentError when weight is -2" do
      # covers:
      #   line 3: unless weight.positive? -> then
      expect { Shipping.fee(-2) }.to raise_error(ArgumentError, "weight must be positive")
    end

    it "raises ArgumentError when weight is 0" do
      # covers:
      #   line 3: unless weight.positive? -> then
      expect { Shipping.fee(0) }.to raise_error(ArgumentError, "weight must be positive")
    end

    it "returns 5 when weight is 1" do
      # covers:
      #   line 3: unless weight.positive? -> else
      #   line 5: weight <= 2 ? 5 : 5 + (weight - 2) * 2 -> then
      #   line 6: express ? base * 2 : base -> else
      expect(Shipping.fee(1)).to eq(5)
    end

    it "returns 7 when weight is 3" do
      # covers:
      #   line 3: unless weight.positive? -> else
      #   line 5: weight <= 2 ? 5 : 5 + (weight - 2) * 2 -> else
      #   line 6: express ? base * 2 : base -> else
      expect(Shipping.fee(3)).to eq(7)
    end
  end
end
```

```sh
rspec shipping_spec.rb
```

```text
.....

Finished in 0.00334 seconds (files took 0.07131 seconds to load)
5 examples, 0 failures

```

次に、フロンティアを閉じる。
足りない腕を通る入力を入力ファイルに書き、同じコマンドを `--inputs` 付きで実行する。

```sh
cat > inputs.json <<'JSON'
{"inputs": [{"args": [3], "kwargs": {"express": true}}]}
JSON
branchout explore shipping.rb Shipping.fee --inputs inputs.json --emit-tests shipping_spec.rb
```

```text
branchout explore shipping.rb Shipping.fee
covered: 6 of 6 arms by 14 inputs
raised: 3 inputs
tests: shipping_spec.rb

FRONTIER
(none)

EXCEPTIONS
ArgumentError at shipping.rb:3: weight must be positive
  inputs: [-1], [-2], [0]

Pass --verbose for every covered arm and the run settings.
```

```sh
rspec shipping_spec.rb --format documentation
```

```text
Shipping
  .fee
    raises ArgumentError when weight is -1
    raises ArgumentError when weight is -2
    raises ArgumentError when weight is 0
    returns 5 when weight is 1
    returns 14 when weight is 3 and express is true

Finished in 0.00228 seconds (files took 0.07051 seconds to load)
5 examples, 0 failures
```

これですべての腕を通った。
書き出したスペックは、入力ファイルの入力をすべて残し、それ以外は腕ごと、例外ごとに 1 件の入力を残す。
スペックはコードの横に置いておく。
メソッドのふるまいが変わると失敗する。
コーディングエージェントも同じループを回す。
`FRONTIER` を読み、入力を足し、再実行する。
その手順は [skills/branchout/SKILL.md](skills/branchout/SKILL.md)（英語）にある。

## CLI リファレンス

テストを足しているエージェントは、腕が未達であることまではカバレッジで分かる。どの比較で外れたか、どの入力が決定のいちばん近くまで届いたかは分からない。branchout はそのフロンティアを、条件と、腕を選ぶ向きと、決定に届いた最も近い入力とともに出す。エージェントは入力を足して同じコマンドを再実行する。branchout は入力ファイルを書き換えない。探索が終わると、発見した戻り値または例外を固定する minitest か RSpec を書く。

方法はコンコリックテスト（[DART](https://doi.org/10.1145/1065010.1065036)、[CUTE](https://doi.org/10.1145/1094811.1094816)）と、[ConcoLLMic](https://concollmic.github.io/) のような LLM が導くコンコリックに沿う。branchout はコンコリックテストに着想を得ているが、記号制約は解かない。次の入力は、エージェントが分岐フロンティアから提案する。

このリポジトリのチェックアウトでは、`ruby bin/branchout` が `branchout` と同じコマンドを実行する。
種ファイルの入力は `[0]` の 1 件である。
`--verbose` はレポート全体を出す。
実行の設定と件数のあとに、`COVERED`（各腕を通った入力）、`FRONTIER`（どの入力も通らなかった各腕と、`nearest` が通った腕の `path`）、`EXCEPTIONS`（例外を出した入力ごとに 1 件）、`NOT COUNTED`、`OPERATORS` が続く。
付けないときのレポートは、件数と、入力が届いた `FRONTIER` の腕を、変えるべき `nearest` の入力の下に 1 行ずつと、どの入力も届かなかった決定ごとに 1 行と、例外ごとに 1 行を残す。
[アプリなしで試す](#アプリなしで試す) の出力がその形である。
`--json` は、レポート全体のすべての項目を持つ。

```sh
ruby bin/branchout explore examples/magic_value.rb MagicValue.classify \
  --inputs examples/inputs/magic_value.seed.json \
  --strategy inputs \
  --random 0 \
  --seed 1 \
  --verbose
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
callees_not_counted: 0
operators_not_counted: 0

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

NOT COUNTED
(none)

OPERATORS
(none)
```

`cond: x == 114514` の `sense: cond-true` が、`[0]` では通らなかった腕である。`[114514]` を足して同じコマンドを再実行する。`examples/inputs/magic_value.json` がそのファイルで、`arms_covered: 2`、`FRONTIER` は `(none)` になる。

`ENTRY` は `Const.method` か `Const#method`。
`module_function` のメソッドと、`extend self` したモジュールのメソッドは `Const.method` で指定する。
`Const#method` では、入力ごとに `Const.new` で新しいレシーバーを作る。
`initialize` が引数を取るときは、各入力の `new` に入力と同じ形で書く。
`{"args": [5], "new": [10]}` は `Const.new(10).method(5)` を呼ぶ。
キーワードだけを渡す `new` は `args` を省ける。
`{"args": [5], "new": {"kwargs": {"main": 1}}}` は `Const.new(main: 1).method(5)` を呼ぶ。
メソッドが読む状態が `new` のあとの呼び出しで決まるときは、その呼び出しを順に `setup` へ書く。
`{"args": [], "setup": [{"method": "add", "args": ["apple", 3]}]}` は、新しいレシーバーで `add("apple", 3)` を呼んでからメソッドを呼ぶ。
各ステップは `method`、`args`、`kwargs` を取る。
カバレッジが数えるのはメソッドの呼び出しだけで、`new` と `setup` は数えない。
対象ファイルが `initialize` を定義していれば、`mutate` と `random` はその引数から `new` も埋める。
`--entry ENTRY` は位置引数の代わりになる。

探索中は `--strategy inputs --random 0` とし、`--seed` は固定する。新しく覆われた腕は、足した入力だけから来る。探索手順は [skills/branchout/SKILL.md](skills/branchout/SKILL.md) にある。

| フラグ | 既定 | 意味 |
| --- | --- | --- |
| `--inputs PATH` | なし | 入力の JSON ファイル |
| `--require PATH` | なし | ターゲットより先に PATH を読み込む。ライブラリの残りが要るターゲットに使う。繰り返し指定できる。PATH のディレクトリはロードパスの末尾、gem の後に入るので、`lib/name.rb` は `require "name/part"` でき、`config/environment.rb` の隣の `config/puma.rb` が puma gem を隠さない。作業ディレクトリの下にファイルがない PATH は、`ruby -r` と同じく機能名として読む。`--require shop -I lib` は `lib/shop.rb` を読み込み、どの `-I` ディレクトリにもない名前はロードパスから探す。出力するテストも PATH を読み込む |
| `-I DIR` | なし | 探索中、`ruby -I` と同じく DIR をロードパスに入れる。繰り返し指定できる。`--require-by-name` を付けると、DIR の下のファイルは DIR からの名前で読み込む。`app/models` の下の Rails のモデルなどに使う |
| `--seed N` | `0` | 乱数の種 |
| `--random N` | `16` | ランダム標本の個数 |
| `--mutate-cap N` | `256` | リテラル変異の予算 |
| `--strategy LIST` | `inputs,mutate,random` | 戦略をカンマ区切りで、下の表の順に実行する |
| `--timeout SEC` | `1` | 入力 1 件の制限時間。0 より大きいこと |
| `--verbose` | オフ | テキストのレポート全体を出す。実行の設定、通った腕すべて、フロンティアの各腕の `path` を含む。`explore` のみ |
| `--json` | オフ | テキストの代わりに JSON を標準出力へ出す |
| `--json-out PATH` | | JSON レポートを書く |
| `--md-out PATH` | | `--verbose` が出すテキストレポートを Markdown で書く |
| `--emit-tests PATH` | | 特徴づけテストを書く。`explore` のみ |
| `--format NAME` | `minitest` | `minitest` か `rspec`。`--emit-tests` が要る。省くと、パスが `_spec.rb` で終わるときだけ RSpec |
| `--pin-keys LIST` | | キーのカンマ区切り。戻り値の Hash はこのキーだけを固定する（minitest は `slice`、RSpec は `include`）。後からキーが増えてもテストは落ちない。`--emit-tests` が要る |
| `--require-by-name` | オフ | 出力するテストは `--require` のファイルと対象を、ロードパス経由で `require` する。名前は、そのファイルを含む最初の `-I` ディレクトリか `--require` ファイルのディレクトリから作る（`require "shop/cart"`）。どちらもないときは、対象より上で最も近い `lib` ディレクトリか、対象自身のディレクトリから作る。どのディレクトリにも入らないファイルはパスで読み込み、その上のコメントと標準エラーの 1 行がそう伝える。require の上の `# Load path: -I lib` というコメントが、テストに要るロードパスのディレクトリを示す。RSpec のファイルは、rspec が自分で入れる `spec` と `lib` を挙げない。`--emit-tests` が要る。`.jitcatch` ディレクトリの下に出すテストは、このフラグがなくてもこうなる。jitcatch はそのテストを各チェックアウトにコピーし、rerun の行は書いた場所から読み込むので、`require_relative` では場所ごとに別のファイルを読み込むからである |
| `--entry ENTRY` | 位置引数 | `Const.method` か `Const#method` |

| 戦略 | 実行するもの |
| --- | --- |
| `inputs` | 入力ファイルの各エントリ。canonical JSON が同じものは捨てる |
| `mutate` | ソースのリテラルを各引数スロットへ入れる。整数には `0`、`1`、`-1`、リテラル±1 も含む。浮動小数には `0.0`、`1.0`、`-1.0`、±1 も含む。文字列には `""`、`"a"`、末尾 1 文字を落としたリテラル、リテラルに `"1"` を足したものも含む。先頭 2 つの位置引数が数値のときは、そのスロットの直積も作り、`--mutate-cap` で切る。文字列リテラルは連結しない。リテラルはエントリと、それが同じファイルで呼ぶ各メソッドから集める。ファイルがリテラルを入れる定数（`HOLD = "sanctions"`）はそのリテラルとして数える。スロットの型も同じメソッドから決める。ヘルパーに渡した引数は、ヘルパーが受けた引数をどう使うかで型が決まる（`def held?(text) = text == HOLD` に `held?(reason)` と渡すと `reason` は String になる）。`doc["key"]` や `doc.dig(:key)` は `doc` を Hash にする |
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

エントリは配列だけでもよい。
キーワードは `kwargs` に、コンストラクタ引数は `new` に、レシーバーの状態を作る呼び出しは `setup` に書く。
保存済みのレコードのように `new` では作れないレシーバーは、`receiver` に Ruby で書く（`{"receiver": {"ruby": "Factories.loan(3)"}, "args": [{"ruby": "loan.amount"}]}`）。
レシーバーには、出力するテストと同じ名前（クラス名のスネークケース）が付くので、引数と `setup` からそのレシーバーを読める。
型推論が違うときは、`"types"` に位置引数 1 つにつき `int`、`float`、`string`、`array`、`hash`、`bool` のいずれかを置く。
既定値が `[]`、`{}`、`true`、`false` の引数はその型になる。
`bool` の引数には、変異とランダムサンプリングが `false` と `true` の両方を試す。
`meta` のような他のトップレベルキーは無視する。
各エントリの `note` も無視するので、その入力を選んだ理由をすぐ横に書ける。
エントリの `pin_keys`（`{"args": [3], "pin_keys": ["tax"]}`）は、その入力のテストに限って `--pin-keys` の代わりになる。
`"pin_keys": []` は、その Hash を丸ごと固定する。
レコードや例外のように JSON で書けない値は、`{"ruby": "..."}` に Ruby で書く。
`--require` したファイルのファクトリを呼ぶことが多い（`{"args": [{"ruby": "Factories.loan(3)"}]}`）。
呼び出しごとにトップレベルで評価し直し、出力するテストは書いたとおりに写す（`Lending.approve(Factories.loan(3))`）。
メソッドが受け取るブロックは、波かっこで `block` に書く（`{"args": [5], "block": "{ |amount| amount > 2 }"}`）。
キーが `"ruby"` 1 つだけの Hash 引数も Ruby で書く（`{"ruby": "{\"ruby\" => \"3.4\"}"}`）。
出力するテストのプロジェクト（テストより上で最も近い、`Gemfile`、gemspec、`.git` のいずれかがあるディレクトリ）の下のパスを指す String は、テスト自身のディレクトリから書く（`File.expand_path("../fixtures/files/rates.csv", __dir__)`）。
そのためテストは、jitcatch のコピーを含め、プロジェクトのどのチェックアウトでも通る。
テストの名前と説明は、プロジェクトのルートからのパス（`spec/fixtures/files/rates.csv`）で書く。
プロジェクトの外で、一時ディレクトリかホームディレクトリの下にあるパスは書いたとおりに残し、標準エラーがそのパスを示す。
実在するパスなら、そのテストはこのマシンでしか通らないからである。
実在しないパスでも、テストにこのマシンのディレクトリが残るからである。
そうしたパスは、たとえば `spec/fixtures/files` のようにプロジェクトの下に置く。
戻り値やエラーメッセージがプロジェクトの下のパスを含むときも、プロジェクトのルートをテスト自身のディレクトリから書く（`"No such file or directory @ rb_sysopen - #{File.expand_path("..", __dir__)}/spec/fixtures/none.csv"`）。
プロジェクトの外にあるこのマシンのパスを含むときは書いたとおりに残し、標準エラーがそのパスを示す。
テストの名前と説明は、一時ディレクトリかホームディレクトリの下のパスをファイル名だけで書くので、どのマシンでも同じになる。
エントリは末尾へ足す。
消したり並べ替えたりしない。

```sh
ruby bin/branchout explore examples/hidden_bug.rb HiddenBug.scale \
  --inputs examples/inputs/hidden_bug.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests spec/generated/hidden_bug_spec.rb \
  --format rspec
```

この実行は 4 腕のうち 4 腕を覆い、`[24,12]` で `ZeroDivisionError`（`divided by 0`）を記録する。出力ファイルは戻り値、または例外クラスとメッセージを固定する。
複数行のメッセージは、発生したときのまま固定する。
各テストの先頭にある `# covers:` の一覧は、その入力が通った腕を 1 行に 1 つずつ示す。
各行は、条件の行番号、書かれたままの条件、通った腕である（`line 20: unless rate.is_a?(Numeric) -> else`、`line 9: elsif tag.start_with?("beta") -> then`）。
三項演算子は式全体を書く（`line 10: label ? :noted : :plain -> then`）。
`case` の腕は、その腕を示す `when`、`in`、`else` の行に置く（`line 6: when 1, 2 then :low`）。
`NameError` と `NoMethodError` は、クラスと見つからなかった名前（`error.name`）で固定する。
Ruby 3.4 でメッセージの文言が変わったためである。
バックトレースのフレーム（`lib/x.rb:3:in 'Box.run'`）を含むメッセージは正規表現で照合し、フレームのラベルだけはどちらの書式でも通す。
Ruby 3.4 はラベルを `` `run' `` から `'Box.run'` に変えたためである。
`raised in:` の行のように、フレームを含む String の戻り値も同じように照合する。
`Set` は要素で固定する（`Set[1, 2]`）。
`Object` のように Ruby のリテラルで書けない戻り値は、クラスだけを固定する。
RSpec では、`Struct` と `Data` の値はクラスとメンバーで固定し、それを含む Array や Hash は要素ごとに固定する（`match([a_kind_of(Rule).and(have_attributes(action: "borrow"))])`）。
minitest は `Struct` をクラスだけで固定する。
期待する Hash は値そのもののキー順で書くので、失敗時の差分をキーごとに見比べられる。
private や protected の入口と private な `new` は、`explore` と同じく `send` で呼ぶ。
String の引数は素のリテラルで書き、ファイルの `frozen_string_literal` がそれを凍結する。
`explore` も凍結した String を渡す。
凍結した String では `FrozenError` を起こし、凍結していない String では起こさない入力だけは、凍結していない方の実行を残す。
そのテストは各 String を `+"..."` と書き、その理由をコメントで示す。
この実行は 2 回目で、1 回目の実行が例外の前に変えたものを見ている。
セーブポイントは行を取り消すが、グローバル、クラス変数、ファイルはどの実行も取り消さない。
コメントもこのことを示す。
その値は、出力したテストを単独で実行して確かめる。
`private_constant` で隠したクラスやモジュールは `const_get` でたどり（`Shop.const_get(:Ledger)`）、RSpec の describe はその名前を文字列で書く。
minitest のテスト名は入力と結果から作る。
`test_24_12_raises_zero_division_error` のようになる。
名前が同じになる入力どうしは、互いに異なる値で名付ける（`test_status_timeout_and_error_class_timeout_returns_ok` など）。
そのため、入力を足すとそれらの名前が変わることがある。
先頭が同じ文字列どうしは、分かれたところからの単語で名付ける。
`receiver` の 2 つのファクトリー呼び出しのように先頭が同じ Ruby のソースは、分かれる直前の単語も残す（`test_limit_100_returns_ok`）。
名前は単語の切れ目で切る。
空白だけの文字列は `blank` になり、空の配列や Hash の引数は `empty_array` や `empty_hash` になる。
Hash の引数は値で名付ける。
Hash の引数の中のコレクションは、キーと大きさで名付ける（`groups_3`、`tags_empty`）。
コレクションの配列は大きさで名付ける（`array_of_2`）。
スカラーとコレクションが混ざる配列は、`array` を付けて、各スカラーと各 Hash のキーで名付ける（`returns [:ok, a Hash of id, name]`、`returns_array_ok_hash_id_and_name`）。
`["Done", []]` は文字列 `"Done"` と読めないよう `returns_array_done_empty_array` になる。
16 桁以上の数は、先頭 3 桁と 10 の累乗で名付ける（`123e46`）。
別の葉も同じキーで終わるときは、その上のキーも名前に入れる（`id` の隣の `items_id`）。
Hash の結果は、兄弟どうしを見分けられる最少の葉で名付ける。
入れ子の葉も対象になる（`returns_due_cents_0_and_discount_100`）。
minitest と RSpec は同じ葉を使う。
兄弟がないときはキーで名付ける（`returns_hash_lines_and_discount_cents`）。
2 つ目からのキーの前には `and` を置き、キーは途中で切らない。
スカラーの配列は `array` を付けて名付ける（`[nil]` は `returns_array_nil`）。
`nil`、`true`、`false` と読める文字列やシンボルには `text` を付ける（`returns_text_nil`）。
対象のディレクトリの外に出力したテストは、対象を絶対パスで読み込む。
`--require-by-name` を付け、`-I` か `--require` のディレクトリが対象を含むときは、ロードパス経由で読み込む。
テストが自分のプロジェクト（`Gemfile`、gemspec、`.git` のどれかがある最も近いディレクトリ）の外のファイルをパスで読み込むときは、絶対パスでも別のプロジェクトへ上る相対パスでも、このマシンのその場所でしか動かないことを標準エラーで警告し、直し方を示す。
`--require` のファイルがすでに対象を読み込むときは、対象の require を書かない。

RSpec のファイルは定数を describe し、その中で `.method` か `#method` を describe する。
レシーバーは `let` に、各 setup 呼び出しは `before` に置く。
レシーバー、呼び出し、引数の値が先頭から同じ入力どうしは、1 つの `context` を共有する。
各 example はまず結果を述べ、次にその example だけの引数の値を述べる。
そのため `rspec --format documentation` は仕様のように読める。
引数の中の値は、そこへのパスで名付ける。
スカラーの配列は全体で名付ける（`items is [1, 2]`）。
パスは String のキーを引用符付きで、Symbol のキーを引用符なしで書く。
そのため Rails の params のような String キーの Hash が、Symbol で引けるようには読めない。
JSON の入力 `[{"sku": "B"}]` は `items[0]["sku"] is "B"` と読み、Ruby のリテラル `{"ruby": "[{sku: \"B\"}]"}` は `items[0].sku is "B"` と読む。
`{"ruby": ...}` の Ruby が単純なリテラルなら、どちらの形式でも同じようにその値で名付ける。
Hash の結果は、各キーをリテラルと同じ形で書く（`returns "state" => "open"`、`returns due_cents: 0`）。
String のキーの下にある葉は、それを持つリテラルで書き、同じキーの下の葉は一つのリテラルにまとめる（`returns "counts" => {"discarded" => 1}`、`returns "tests" => [{"file" => "a_spec.rb", "disposition" => "flaky"}]`）。
context は、兄弟と見分けるのに要る値だけを述べる。
文は 80 文字を超えない。
長くなる example は、兄弟と見分けるのに要る値だけを、いちばん深いキーで述べる（`when status is "timeout"`）。
別の葉も同じキーで終わるときは、見分けられるところまで上のキーも書く（`when result.status is "timeout"`）。
String のキーは、引数とその葉を持つリテラルで書く（`when doc holds "status" => "timeout"`、`when doc holds "result" => {"status" => "timeout"}`）。
`doc["status"]` と書くと別の葉を指すからである。
40 文字を超える String とスカラーの配列の結果は、先頭を見せてから切る（`returns ["require_relative \"../lib/shop/cart...`）。
長い文字列は、兄弟と分かれたところで切る。
切れ目が単語の途中に来るときは、その単語の前で切る。
それでも 80 文字を超える example は、見分けるのに要る値を残し、先頭の結果のほうを切る（`returns ["require \"shop\"",... when target_path is "app/cart.rb"`）。
ダブルクォートを含む文は、エスケープが要らないようにシングルクォートで書く。
文の中の String の値がバックスラッシュを含むときも同じである（`'returns 1 when x is "say \"hi\""'`）。

```text
Arithmetic
  .classify
    returns :miss when x is 0, y is 0 and z is 0
    returns :miss when x is 114514, y is 0 and z is 0
    when x is 138
      returns :x_only when y is 0 and z is 0
      when y is 143
        returns :need_z when z is 0
        returns :hit when z is 7
```

どの入力でも引数をとらないメソッドは `subject` になる。
例外を出した入力は、setup の呼び出しを `expect` のブロックの中に残す。
そのため setup で出た例外も固定できる。
minitest のパスは `--format minitest` で、`ruby` で実行する。RSpec には `rspec` gem が要る。

## テストスイートの中で使う

`Branchout.explore` はテストの中から動き、CLI と同じレポートを返す。
Gemfile の行と探索のスペックの例は [Rails アプリでのクイックスタート](#rails-アプリでのクイックスタート) にある。
スペックの 1 行目の `require "branchout/coverage" if ENV["BRANCHOUT"]` は、ヘルパーがアプリを起動する前に Coverage の準備をする。
そのためモデルはその後に読み込まれる。
minitest では `require "test_helper"` の前に置く。
Rails のないスイートでも同じように動く。

探索のファイルは単独で実行する。
スイート全体の実行では、別のスペックファイルが先にモデルを読み込むことがある。
`.rspec` が `rails_helper` を require していると、スペックの 1 行目より前にアプリが起動する。
そのため、イニシャライザが読むモデルは早すぎる時点で読み込まれ、explore はそれを断る。
テスト環境が eager load する（`config.eager_load`。Rails は `ENV["CI"]` から決める）と、すべてのモデルが同じことになる。
Rails より前に準備すると、Coverage はすべての gem も計測する。
クイックスタートのサンプルアプリでは、`spec/rails_helper.rb` の `config/environment` を読み込む行のすぐ後に置いた場合と比べて、探索の実行は起動が約 0.3 秒、入力 1 件ごとに約 12 ms 長くなった。
起動中にモデルを読み込むものがなければ、その置き方のほうが速い。
その時点で gem は読み込み済みで、モデルは最初に使うときに読み込まれる。

入力は入力ファイルのエントリの並びか、そのファイルのパスである。
入力の Ruby はそのテストの中（`within: self`）で動くので、スイートのファクトリ、フィクスチャ、ヘルパーを使える。
ActiveRecord が読み込まれていれば、各入力はセーブポイントの中で動き、最後にロールバックされる。
そのため、ある入力が書いた行を別の入力は見ず、テスト自身の行もそのまま残る。
`around:` に、入力をブロックとして受け取るラムダを渡すと、これを置き換えられる。
凍結した String で `FrozenError` を起こした入力を凍結していない String でもう一度実行するのは、その入力が `Branchout::ROLL_BACK` の中で動いたときだけである。
既定の場合と、`Branchout::ROLL_BACK` を呼ぶ `around:` の場合がそれにあたる。
`Branchout::RUN_ONLY` などそれ以外の `around:` では `FrozenError` を固定する。
その `around:` が 1 回目の実行の行を取り消したかどうかを branchout は判断できないためである。
戦略は `strategies:` で変えない限り `inputs` だけで、`timeout:` は指定しない限り 1 秒である（`nil` で切る）。
`target:`、`emit_tests:`、`format:`、`json:`、`verbose:`、`pin_keys:`、`requires:`、`seed:`、`random:`、`mutate_cap:` は、CLI の同名のフラグと同じ意味である。
minitest では、同じ呼び出しを `ActiveSupport::TestCase` のテストに書き、`BRANCHOUT=1 bin/rails test` で動かす。

出力するテストは、スイートが読み込んだヘルパー（`rails_helper`、なければ `test_helper`、なければ `spec_helper`）を名前で require する。
どれも読み込んでいないスイートは、`requires:` でヘルパーを指定する。
ファイルを指さない `requires:` の要素はロードパスで探し、どこにもなければ `requires: "spec/helper" names no file under the working directory or on the load path` で止まる。
指定しないと `emit_tests:` を断る。
モデルはアプリが読み込むので require しない。
minitest のテストは、探索したテストの基底クラス（`ActiveSupport::TestCase` など）を継承する。
RSpec のファイルは、探索した example group の `type`（`type: :model` など）を `describe` に付ける。
rspec はプロジェクトの `spec` と `lib` を自分でロードパスに入れるので、RSpec のファイルの `# Load path:` コメントはこの 2 つを挙げない。
他のテストと同じく、`BRANCHOUT` なしで実行する。

Coverage が数えるのは、`branchout/coverage` の後に読み込まれたファイルだけである。
それより前に読み込まれたターゲットは、読み込み直さずに断る。
モデルを読み込み直すと、バリデーションが二重に宣言されるからである。
ヘルパーで SimpleCov を始めるスイートは、`branchout/coverage` の前でも後でも、変えなくてよい。
その実行は branchout が計測し、SimpleCov はその実行を 0% と報告する。
explore は入力ごとに数を消すからである。
入力の Ruby は、探索する example のローカル変数を読んではいけない。
`let` や `subject` を読む入力は断る。
出力するファイルにはどちらもないからである。
また、入力の中で初めて読まれた `let` は、その入力のロールバックされるセーブポイントの中で作られ、次の入力に持ち越される。

CLI でも、`RAILS_ENV=test` と `--require config/environment.rb` でアプリを読み込める。
ただしその場合、各入力の行はテスト用データベースに残り、後の入力はそれを見る。
テストのヘルパーも使えない。

## フロンティアの作り方

`--require` のファイルと対象ファイルは `Coverage.setup(lines: true, branches: true)` のあとで読み、ロード時のカウントは捨てる。入力ごとに coverage を resume し、メソッドを呼び、suspend して `Coverage.result` を読む。残すのは入口メソッドと、同じファイル内で裸呼び出しまたは `self.` から届く callee だけである。
`--require` のファイルが `require` か、Rails が initializer を読むときの `Kernel#load` で読み込み済みの対象は、もう一度は読まない。
`def self.apply(doc) = new(doc).apply` のように自分のインスタンスを作るクラスメソッドは、`initialize` と、そのインスタンスで呼ぶメソッドまで追う。
`new(path).tap(&:parse)` や `then(&:parse)` で呼ぶメソッドも追う。

別のファイルのメソッドは数えないので、その腕は `arms_total` に入らない。
サブクラスのメソッドにあった検査を親クラスのヘルパーに移すと、ロジックは同じでも合計が小さくなる。
`NOT COUNTED` はそういう callee を挙げる。
数えたコードが裸呼び出しか `self.` で呼び、Ruby が別のファイル（親クラスや mixin など）で見つけるメソッドである。
`Const.new` で作ったオブジェクトに呼ぶメソッドも挙げる。
そのオブジェクトは、ローカル変数（`journal = Ledger.new`）か、クラスのメソッドが設定するインスタンス変数（`initialize` の `@ledger = Ledger.new`）に入っているものである。
各項目には `callee`（`Register#required_sku`）、`loc`（その `def` のファイルと行）、`arms`（その `def` の中の分岐の腕の数）がある。
そのファイルが coverage の開始より前に読み込まれたときや、`define_method` のように `def` がないときは、`arms` は `unknown` になる。
その腕を通すには、callee を入口にして explore する。
インストールした gem や Ruby 自身のライブラリのメソッドは挙げない。
アプリはそこへ検査を移せないからである。
Rails のモデルは、関連の reader や `update!` など、その種のメソッドを何十も呼ぶ。
C で書かれたメソッド、Ruby 自身の prelude のメソッド、属性の reader と writer、腕のないメソッド、クラスがコードから分からないオブジェクトへの呼び出しは挙げない。

分岐カバレッジは `||`、`&&`、`||=`、`&&=` に腕を数えないので、右辺が実行されたかどうかは分からない。
`user&.admin? || params[:force]` の `&.` より先のように、これらだけで分岐するメソッドは、実際より少ない腕を報告する。
腕が 1 つもなければ `arms_total: 0` になり、すべてカバーしたように読める。
`OPERATORS` は、数えたコードにあるそうした演算子を 1 つずつ挙げ、`operators_not_counted` がその数を示す。
各項目には `loc`（演算子の行と列）、`op`、`text`（式全体で、160 文字で切る）がある。
左辺が真になる入力と偽になる入力を与える。
入口に腕がなく、そうした演算子があるときは、stderr がそう伝える。
`&.` には自分の腕がある（`receiver-present`、`receiver-nil`）。

腕の id は Coverage の分岐キーから作る `kind@行:列/arm@行:列` である。列は 0 始まり。`cond` は Prism の述語で、`when` または `in` の腕ではその行である。位置が一致しないときはソースの行を使う。

フロンティアはカウントが 0 の腕である。`parent: reached` は、どれかの入力がその決定を実行したことを意味する。`nearest` は、そこに届いた入力のうち、通った腕が最も少なく、次に重み（数の絶対値に、文字列とコンテナの長さを足したもの）が最も小さく、次に canonical JSON が最も小さいものである。`path` は、その入力が通った腕のソート済み集合である。Coverage は順序を記録しない。ループ回数が 1 を超えると `*回数` を付ける。

`sense` は腕を選ぶ向きである。`cond-true`（`if` の then、`unless` の else）、`cond-false`（`if` の else、`unless` の then）、`arm-matched`（その `when` または `in`）、`arm-else`、`body-entered`（`while` または `until` の本体）、`receiver-present`、`receiver-nil`（`&.`）。

例外は腕のカバーとは別に出す。カバー済みの腕でも例外は起きる。同じ入力、同じフラグ、同じ CRuby なら標準出力は同じバイト列になる。前の入力と同じ入力は一度だけ実行し、重複した数を標準エラーに出す。レポートに時刻はない。パスは作業ディレクトリからの相対パスである。

## インストール

Ruby 3.3 以降。探索に使うのは標準ライブラリの Coverage、Prism、json である。Gemfile に `gem "branchout", group: :test, require: false` を書いて `bundle exec branchout` を実行するか、このチェックアウトで `ruby bin/branchout` を実行するか、`bin` を `PATH` に置く。出した minitest は `ruby` で実行する。出した RSpec には `rspec` gem が要る。バンドルの外では、`bin/branchout` は入っているどの gem も受け入れる prism のうち最も新しいものを有効にする。そのため、より新しい prism が入っていても、minitest 6 (prism ~> 1.5) を require するターゲットは読み込める。

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

- 対象は実際に実行される。対象の標準出力と標準エラーは、ロード時も呼び出しごとにも捨てる。ファイル、グローバル、ネットワークはサンドボックスしない。
- `FrozenError` を起こして凍結していない String でもう一度実行した入力は、1 回目の後に同じプロセスで動く。1 回目の実行が変えたグローバル、クラス変数、ファイルは元に戻らない。
- 対象は branchout と同じプロセスに読み込まれる。
  別のチェックアウトの branchout を読み込む対象や `--require` のファイルは、ツール自身のクラスを置き換えるので拒否する。
  branchout 自身のコードを調べるときは、そのチェックアウトの `bin/branchout` を使う。
  引数がツール自身のファイルを指すとき、ツールは自分を読み込む前に coverage を準備する。
  そのため、そのファイルを読み込み直さずに coverage が測れる。
  coverage の準備より前に読み込まれたファイル、たとえば Ruby 自身のライブラリは拒否する。
  読み込み直すとクラスが二度定義され、最初のクラスで作ったオブジェクトがそのクラスのものでなくなるからである。
- 入口は対象ファイルの中で、その定数か、同じファイルで宣言したスーパークラスの下に定義されていなければならない。
  継承した入口は、Ruby と同じくサブクラスの上書きを追う。
- 時刻、乱数、I/O に依存するメソッドは、同じ入力でもレポートが揃わない。
- 経路は腕の集合であり、順序ではない。`&&`、`||`、`||=`、`&&=` は腕にならず、`OPERATORS` に挙がる。`while` と `until` が記録するのは本体の腕で、条件は実行されたが本体に入らなかったことは行カウントで補う。
- 修飾子の `unless` は then と else が同じ位置になることがある。id の腕名で区別する。
- 追うのは同じファイルの裸呼び出し、`self.` 呼び出し、裸の `new(...)` に対する呼び出しだけである。
  `Other.new.check(x)` のような別のレシーバーへの呼び出しは追わない。
  入口がどの腕にも届かないとき、`explore` は stderr に警告を出す。
  この場合は分岐するメソッドを対象にする。
  それでも `--emit-tests` は入力ごとの戻り値または例外を固定する。
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

`test/run_all.rb` は `test/test_*.rb` と `test/generated/*_test.rb` を読み込む。
プロパティテストは hegeltest を使うので、Ruby 3.4 以上が要る。
Ruby 3.3 では `BUNDLE_WITHOUT=property bundle install` とし、プロパティテストはスキップ 1 件になる。
`spec/generated/` は `examples/` から出した RSpec である。Coverage はプロセス全体で 1 系統なので、CLI のテストは branchout をそれぞれ別のプロセスで動かす。
fork が使えるときは、branchout を読み込み済みのサーバーから fork する。

## ライセンス

MIT
