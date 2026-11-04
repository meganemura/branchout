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
callees_not_counted: 0

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
| `--require PATH` | なし | ターゲットより先に PATH を読み込む。ライブラリの残りが要るターゲットに使う。繰り返し指定できる。PATH のディレクトリはロードパスの末尾、gem の後に入るので、`lib/name.rb` は `require "name/part"` でき、`config/environment.rb` の隣の `config/puma.rb` が puma gem を隠さない。出力するテストも PATH を読み込む |
| `-I DIR` | なし | 探索中、`ruby -I` と同じく DIR をロードパスに入れる。繰り返し指定できる。`--require-by-name` を付けると、DIR の下のファイルは DIR からの名前で読み込む。`app/models` の下の Rails のモデルなどに使う |
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
| `--pin-keys LIST` | | キーのカンマ区切り。戻り値の Hash はこのキーだけを固定する（minitest は `slice`、RSpec は `include`）。後からキーが増えてもテストは落ちない。`--emit-tests` が要る |
| `--require-by-name` | オフ | 出力するテストは `--require` のファイルと対象を、ロードパス経由で `require` する。名前は、そのファイルを含む最初の `-I` ディレクトリか `--require` ファイルのディレクトリから作る（`require "shop/cart"`）。どちらもないときは、対象より上で最も近い `lib` ディレクトリか、対象自身のディレクトリから作る。どのディレクトリにも入らないファイルはパスで読み込み、その上のコメントと標準エラーの 1 行がそう伝える。require の上の `# Load path: -I lib` というコメントが、テストに要るロードパスのディレクトリを示す。`--emit-tests` が要る |
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
`private_constant` で隠したクラスやモジュールは `const_get` でたどり（`Shop.const_get(:Ledger)`）、RSpec の describe はその名前を文字列で書く。
minitest のテスト名は入力と結果から作る。
`test_24_12_raises_zero_division_error` のようになる。
名前が同じになる入力どうしは、互いに異なる値で名付ける（`test_status_timeout__error_class_timeout_returns_ok` など）。
そのため、入力を足すとそれらの名前が変わることがある。
先頭が同じ文字列どうしは、分かれたところからの単語で名付ける。
`receiver` の 2 つのファクトリー呼び出しのように先頭が同じ Ruby のソースは、分かれる直前の単語も残す（`test_limit_100_returns_ok`）。
名前は単語の切れ目で切る。
空白だけの文字列は `blank` になり、Hash の引数は値で名付ける。
Hash の引数の中のコレクションは、キーと大きさで名付ける（`groups_3`、`tags_empty`）。
コレクションの配列は大きさで名付ける（`array_of_2`）。
スカラーとコレクションが混ざる配列は、各スカラーと各 Hash のキーで名付ける（`returns [:ok, a Hash of id, name]`、`returns_ok_hash__id__name`）。
16 桁以上の数は、先頭 3 桁と 10 の累乗で名付ける（`123e46`）。
別の葉も同じキーで終わるときは、その上のキーも名前に入れる（`id` の隣の `items_id`）。
Hash の結果は、兄弟どうしを見分けられる最少の葉で名付ける。
入れ子の葉も対象になる（`returns__due_cents_0__discount_100`）。
minitest と RSpec は同じ葉を使う。
兄弟がないときはキーで名付け、各キーの前に `__` を置く。
対象のディレクトリの外に出力したテストは、対象を絶対パスで読み込む。
`--require-by-name` を付け、`-I` か `--require` のディレクトリが対象を含むときは、ロードパス経由で読み込む。
`--require` のファイルがすでに対象を読み込むときは、対象の require を書かない。

RSpec のファイルは定数を describe し、その中で `.method` か `#method` を describe する。
レシーバーは `let` に、各 setup 呼び出しは `before` に置く。
レシーバー、呼び出し、引数の値が先頭から同じ入力どうしは、1 つの `context` を共有する。
各 example はまず結果を述べ、次にその example だけの引数の値を述べる。
そのため `rspec --format documentation` は仕様のように読める。
引数の中の値は、そこへのパスで名付ける（`args[0].value is 7`）。
context は、兄弟と見分けるのに要る値だけを述べる。
文は 80 文字を超えない。
長くなる example は、兄弟と見分けるのに要る値だけを、いちばん深いキーで述べる（`when status is "timeout"`）。
別の葉も同じキーで終わるときは、見分けられるところまで上のキーも書く（`when result.status is "timeout"`）。
40 文字を超える String とスカラーの配列の結果は、先頭を見せてから切る（`returns ["require_relative \"../lib/shop/cart...`）。
長い文字列は、兄弟と分かれたところで切る。
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

## テストスイートの中で使う（Rails）

Rails アプリのメソッドの多くは、スイートの中でしか動かない。
アプリの起動、データベース、ファクトリ、テストごとのトランザクションが要るからである。
`Branchout.explore` はテストの中から動き、CLI と同じレポートを返す。

```ruby
# Gemfile
group :test do
  gem "branchout", require: false
end
```

`spec/rails_helper.rb` または `test/test_helper.rb` の、`config/environment` を読み込む行のすぐ後に次の行を置く。

```ruby
require_relative "../config/environment"
require "branchout/coverage" if ENV["BRANCHOUT"]
```

この時点で Rails と gem は読み込み済みで、モデルは最初に使うときに読み込まれる。
そのため Coverage が計測の準備をするのはアプリのコードだけになる。
Rails より前に置くと、すべての gem も計測の対象になる。
ある Rails のスイートでは、モデルのテストが約 25% 長くなった。
`config/environment` の後に置いたときの差は、ばらつきの範囲だった。
テスト環境が eager load する（`config.eager_load`。Rails は `ENV["CI"]` から決める）と、モデルは `config/environment` の中で読み込まれ、explore はそれを断る。
eager load なしで実行する。
Rails のないスイートでは、アプリのファイルを読み込む前、ヘルパーの先頭に置く。

```ruby
# spec/models/loan_explore_spec.rb
require "rails_helper"
require "branchout"

RSpec.describe Loan do
  it "explores approve", if: ENV["BRANCHOUT"] do
    officer = {ruby: "{name: 'Grace', senior: false}"}
    puts Branchout.explore("Loan#approve", within: self, emit_tests: "spec/models/loan_approve_spec.rb", inputs: [
      {receiver: {ruby: "build(:loan, amount: 500)"}, args: [officer]},
      {receiver: {ruby: "create(:loan, :approved)"}, args: [officer]}
    ])
  end
end
```

```sh
BRANCHOUT=1 bundle exec rspec spec/models/loan_explore_spec.rb
```

入力は入力ファイルのエントリの並びか、そのファイルのパスである。
入力の Ruby はそのテストの中（`within: self`）で動くので、スイートのファクトリ、フィクスチャ、ヘルパーを使える。
ActiveRecord が読み込まれていれば、各入力はセーブポイントの中で動き、最後にロールバックされる。
そのため、ある入力が書いた行を別の入力は見ず、テスト自身の行もそのまま残る。
`around:` に、入力をブロックとして受け取るラムダを渡すと、これを置き換えられる。
戦略は `strategies:` で変えない限り `inputs` だけで、`timeout:` は指定しない限り 1 秒である（`nil` で切る）。
`target:`、`emit_tests:`、`format:`、`json:`、`pin_keys:`、`requires:`、`seed:`、`random:`、`mutate_cap:` は、CLI の同名のフラグと同じ意味である。
minitest では、同じ呼び出しを `ActiveSupport::TestCase` のテストに書き、`BRANCHOUT=1 bin/rails test` で動かす。

出力するテストは、スイートが読み込んだヘルパー（`rails_helper`、なければ `test_helper`、なければ `spec_helper`）を名前で require する。
どれも読み込んでいないスイートは、`requires:` でヘルパーを指定する。
指定しないと `emit_tests:` を断る。
モデルはアプリが読み込むので require しない。
minitest のテストは、探索したテストの基底クラス（`ActiveSupport::TestCase` など）を継承する。
他のテストと同じく、`BRANCHOUT` なしで実行する。

Coverage が数えるのは、`branchout/coverage` の後に読み込まれたファイルだけである。
それより前に読み込まれたターゲットは、読み込み直さずに断る。
モデルを読み込み直すと、バリデーションが二重に宣言されるからである。
SimpleCov のような別のツールが始めた Coverage も断る。
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
- 経路は腕の集合であり、順序ではない。`&&` と `||` は腕にならない。`while` と `until` が記録するのは本体の腕で、条件は実行されたが本体に入らなかったことは行カウントで補う。
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
