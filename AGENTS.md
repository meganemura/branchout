# concolic をエージェントが回す

このツールは LLM を呼ばない。フロンティアを読み、入力を足し、同じコマンドを再実行するのは、人間かコーディングエージェントの仕事。

## 1 回のコマンド

探索中はランダムとリテラル変異を切り、足した入力だけが新しいカバーの原因になるようにする。

```sh
ruby bin/concolic explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs \
  --random 0 \
  --seed 1
```

インスタンスメソッドは `Const#method`。クラスは引数なしの `new` で構築できること。

初期ファイルは種を 1 件にする。

```json
{
  "inputs": [
    {"args": [0]}
  ]
}
```

文字列なら `[""]`、配列なら `[[]]`、ハッシュなら `[{}]`。推論が違えばトップレベルに `"types": ["int", "string"]` を書く。`meta` は無視される。既存の要素は消さず、順番も変えない。末尾に足す。

## フロンティアの読み方

標準出力が契約。同じ入力と同じシードならバイト列は一致する。時刻は出ない。id はソート済み。

- `id` は `分岐種@行:列/腕@行:列`。列は Coverage と Prism と同じ 0 始まり。
- `cond` はその決定の条件式（`when` はその行）。
- `sense` はその腕が選ばれる向き。
  - `cond-true` は条件が真（`if` の then、`unless` の else）。
  - `cond-false` は条件が偽（`if` の else、`unless` の then）。
  - `arm-matched` はその `when` / `in`。`arm-else` は case の else。
  - `body-entered` は `while` / `until` の本体。
- `parent: reached` は、その決定を実行した入力がある。ここだけを先に潰す。
- `nearest` は、その決定に到達した入力のうち、通った腕が少なく、数の絶対値が小さく、canonical JSON が小さいもの。
- `path` は nearest が通った腕の集合（ソート済み）。順序は記録されない。空なら `(none)`。
- `parent: not-reached` は、親がまだ実行されていない。先に親を通す。
- `EXCEPTIONS` は実行時例外。分岐が全部埋まってもここが空とは限らない。

`--json` は同じ内容の機械可読形式。

## ラウンド

1. 上のコマンドを実行する。
2. `parent: reached` の未カバー腕を id 順に見る。
3. その腕を反転させる意図の入力を、まだ足していなければ 1 つ足す。`nearest` をコピーし、`cond` と `sense` だけを満たすように変える。ソースのその行も開く。
4. カバー済みの腕のソースに、定数でない分母の除算、範囲外インデックス、明示的な `raise` があるなら、その腕に留まったままそれを発火させる入力を 1 つ足す。まだ足していなければ。
5. 保存して同じコマンドを再実行する。
6. 停止する条件は次のいずれか。
   - `FRONTIER` が `(none)` で、例外の狙いももうない。
   - 残っている `parent: reached` は、すでに反転を試みて失敗したものだけ（条件が充足不能）。
   - ラウンドが 8 に達した。

`parent: not-reached` を、親を通す前にまとめて埋めようとしない。1 ラウンドで足してよいのは、今 reached の腕と、今見えている例外だけ。

## 終わったら

```sh
ruby bin/concolic explore TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --strategy inputs --random 0 --seed 1 \
  --emit-tests test/generated/name_test.rb \
  --json-out reports/name.json \
  --md-out reports/name.md

ruby bin/concolic baselines TARGET.rb Const.method \
  --inputs path/to/inputs.json \
  --seed 1 --random 40
```

`baselines` は random のみ、リテラル変異のみ、inputs のみを並べる。random の整数は -3..12、文字列は長さ 0..3 でアルファベット `abc01.-`。変異はソース中のリテラルと ±1 を各引数に入れ、数値 2 引数の直積は `--mutate-cap`（既定 256）まで。どちらも合同式や `"0-rc1"` のような連結は解かない。

## やらないこと

- このツールに LLM クライアント、API キー、外部コマンドを足さない。
- 秘密を inputs やレポートに書かない。
- ツールは inputs.json を書き換えない。
