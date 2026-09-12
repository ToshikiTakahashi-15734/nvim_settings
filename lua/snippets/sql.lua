-- ============================================================
-- SQL スニペット定義（自分専用のSQLチートシート）
-- ============================================================
-- 使い方:
--   .sql ファイル、または <leader>db で開いたクエリバッファで
--   スニペット名を打つ → 補完候補から選んで <CR> で展開
--   <Tab> で次の穴へ、<S-Tab> で前の穴へ戻る
--
-- 展開は「1行」で出る:
--   改行を挟まず1行のSQLとして展開される。整形したくなったら
--   展開後に自分で改行を入れる。
--
-- 解説はどこにある?:
--   各スニペットの dscr（補完メニューのドキュメント欄）に入れてある。
--   候補を選んでいる最中に右側のプレビューで読める。
--   1行展開では行内に -- コメントを置けない（以降が全部
--   コメント扱いになる）ため、この形にしている。
--
-- 穴を埋める順番について:
--   FROM のテーブル名を「先」、SELECT の列名を「後」に埋める
--   順序にしている。テーブルが決まっていないと、DBのスキーマから
--   列名を提示できないため（先にテーブルを決める方が補完が効く）。
--
-- このファイルの育て方:
--   ・新しく学んだ構文は下に足していく
--   ・保存して Neovim を再起動すれば反映される
-- ============================================================

local ls = require("luasnip")

local s = ls.snippet
local i = ls.insert_node
local fmt = require("luasnip.extras.fmt").fmt
-- rep(n) = n番目の穴に入れた値を、別の場所にも自動で反映するノード
local rep = require("luasnip.extras").rep

ls.add_snippets("sql", {

    -- ========================================================
    -- 取り出す（SELECT）
    -- ========================================================

    s(
        {
            trig = "select",
            dscr = {
                "SELECT 基本形（テーブル → 列 の順で埋める）",
                "表から必要な列だけを取り出す。",
            },
        },
        fmt("SELECT {cols} FROM {tbl};", {
            tbl = i(1),
            cols = i(2),
        })
    ),

    s(
        {
            trig = "selall",
            dscr = {
                "SELECT * 全列を取り出す",
                "列数が多い表では重いので確認用に使う。",
            },
        },
        fmt("SELECT * FROM {tbl} LIMIT {lim};", {
            tbl = i(1),
            lim = i(2, "10"),
        })
    ),

    s(
        {
            trig = "selw",
            dscr = {
                "SELECT + WHERE 条件で絞り込む",
                "  = 等しい / <> 等しくない / > < >= <=",
                "  IS NULL / IS NOT NULL  ← NULL は = では比較できない",
                "  LIKE '%文字%'          ← 部分一致",
                "  IN (1, 2, 3)           ← どれかに一致",
                "  BETWEEN 1 AND 10       ← 範囲（両端を含む）",
            },
        },
        fmt("SELECT {cols} FROM {tbl} WHERE {cond};", {
            tbl = i(1),
            cols = i(2),
            cond = i(3),
        })
    ),

    s(
        {
            trig = "count",
            dscr = {
                "件数を数える",
                "COUNT(列名) は、その列が NULL の行を数えない点に注意。",
            },
        },
        fmt("SELECT COUNT(*) FROM {tbl} WHERE {cond};", {
            tbl = i(1),
            cond = i(2, "1 = 1"),
        })
    ),

    s(
        {
            trig = "orderby",
            dscr = {
                "ORDER BY + LIMIT 並び替えて件数を絞る",
                "DESC = 大きい順、ASC = 小さい順（省略時はASC）。",
            },
        },
        fmt("SELECT {cols} FROM {tbl} ORDER BY {col} DESC LIMIT {lim};", {
            tbl = i(1),
            cols = i(2),
            col = i(3),
            lim = i(4, "10"),
        })
    ),

    -- ========================================================
    -- つなげる（JOIN）
    -- ========================================================

    s(
        {
            trig = "join",
            dscr = {
                "INNER JOIN 両方に存在する行だけ",
                "両方の表にキーが存在する行だけを返す。",
                "片方にしか無い行は、結果から消える。",
            },
        },
        fmt("SELECT {cols} FROM {left} AS a INNER JOIN {right} AS b ON a.{lkey} = b.{rkey};", {
            left = i(1),
            right = i(2),
            lkey = i(3),
            rkey = i(4, "id"),
            cols = i(5, "a.*"),
        })
    ),

    s(
        {
            trig = "ljoin",
            dscr = {
                "LEFT JOIN 左は全部残す",
                "左の表は全行残し、右に相手が無ければ NULL が入る。",
                "「注文が無いユーザーも一覧に出したい」ときはこれ。",
                "※ WHERE で右の列を条件にすると NULL 行が消えて",
                "  INNER JOIN と同じ結果になってしまう。よくある罠。",
            },
        },
        fmt("SELECT {cols} FROM {left} AS a LEFT JOIN {right} AS b ON a.{lkey} = b.{rkey};", {
            left = i(1),
            right = i(2),
            lkey = i(3),
            rkey = i(4, "id"),
            cols = i(5, "a.*"),
        })
    ),

    -- ========================================================
    -- まとめる（集計）
    -- ========================================================

    s(
        {
            trig = "groupby",
            dscr = {
                "GROUP BY + HAVING 列ごとに束ねて集計",
                "集計関数: COUNT(*) 件数 / SUM() 合計 / AVG() 平均",
                "          MAX() 最大 / MIN() 最小",
                "HAVING は集計「後」の絞り込み（WHERE は集計「前」）。",
                "※ SELECT に書けるのは「束ねた列」と「集計関数」だけ。",
            },
        },
        fmt("SELECT {key}, COUNT(*) AS cnt FROM {tbl} GROUP BY {key2} HAVING COUNT(*) > 1;", {
            tbl = i(1),
            key = i(2),
            key2 = rep(2), -- SELECT に書いた列が GROUP BY にも入る
        })
    ),

    s(
        {
            trig = "window",
            dscr = {
                "ウィンドウ関数 グループ内の順位・累計",
                "行を束ねずに、グループ内での順位や累計を出す。",
                "GROUP BY は行が減るが、ウィンドウ関数は行が減らない。",
                "PARTITION BY = 区切る単位（省略すると全体が1区切り）",
                "ORDER BY     = 区切りの中での並び順",
                "関数: ROW_NUMBER() 連番 / RANK() 同順位あり",
                "      SUM() OVER(...) 累計 / LAG() 前の行の値",
            },
        },
        fmt("SELECT {key}, ROW_NUMBER() OVER (PARTITION BY {pkey} ORDER BY {okey} DESC) AS rn FROM {tbl};", {
            tbl = i(1),
            key = i(2),
            pkey = i(3),
            okey = i(4),
        })
    ),

    -- ========================================================
    -- 組み合わせる（サブクエリ・CTE）
    -- ========================================================

    s(
        {
            trig = "cte",
            dscr = {
                "WITH（CTE）途中結果に名前を付ける",
                "途中結果に名前を付けて、下で普通の表として使う。",
                "サブクエリを入れ子にするより読みやすく、書き直しも楽。",
            },
        },
        fmt(
            "WITH {name} AS (SELECT {key}, COUNT(*) AS cnt FROM {tbl} GROUP BY {key2}) SELECT * FROM {name2} WHERE cnt > 1;",
            {
                name = i(1, "tmp"),
                tbl = i(2),
                key = i(3),
                key2 = rep(3),  -- SELECT に書いた列が GROUP BY にも入る
                name2 = rep(1), -- 上で付けた CTE 名が下の FROM にも入る
            }
        )
    ),

    s(
        {
            trig = "subin",
            dscr = {
                "サブクエリ（IN）別クエリの結果で絞る",
                "内側の SELECT の結果を、外側の条件として使う。",
                "内側が返す列は1つだけにする。",
            },
        },
        fmt("SELECT * FROM {tbl} AS a WHERE a.{key} IN (SELECT {skey} FROM {stbl} WHERE {cond});", {
            tbl = i(1),
            key = i(2, "id"),
            stbl = i(3),
            skey = i(4),
            cond = i(5),
        })
    ),

    s(
        {
            trig = "exists",
            dscr = {
                "EXISTS 該当行があるかだけを見る",
                "内側に1行でも該当があるかだけを判定する。",
                "件数を数えないので、IN より速いことが多い。",
                "内側の SELECT は 1 でよい（値は使われない）。",
            },
        },
        fmt("SELECT * FROM {tbl} AS a WHERE EXISTS (SELECT 1 FROM {stbl} AS b WHERE b.{skey} = a.{key});", {
            tbl = i(1),
            stbl = i(2),
            skey = i(3),
            key = i(4, "id"),
        })
    ),

    s(
        {
            trig = "case",
            dscr = {
                "CASE 式 値によって出力を振り分ける",
                "値に応じて出力を振り分ける（プログラムの if に相当）。",
                "上から順に判定し、最初に合致した THEN が採用される。",
            },
        },
        fmt("CASE WHEN {cond1} THEN {then1} WHEN {cond2} THEN {then2} ELSE {else_} END AS {alias}", {
            cond1 = i(1),
            then1 = i(2),
            cond2 = i(3),
            then2 = i(4),
            else_ = i(5, "NULL"),
            alias = i(6, "label"),
        })
    ),

    -- ========================================================
    -- 書き換える（更新系）※実行前に必ず SELECT で確認する
    -- ========================================================

    s(
        {
            trig = "insert",
            dscr = {
                "INSERT 行を追加する",
                "列の並びと VALUES の並びを必ず一致させる。",
            },
        },
        fmt("INSERT INTO {tbl} ({cols}) VALUES ({vals});", {
            tbl = i(1),
            cols = i(2),
            vals = i(3),
        })
    ),

    s(
        {
            trig = "update",
            dscr = {
                "UPDATE 既存の行を書き換える",
                "※ WHERE を書き忘れると全行が書き換わる。取り消せない。",
                "  必ず先に同じ WHERE で SELECT して対象を確認する。",
            },
        },
        fmt("UPDATE {tbl} SET {col} = {val} WHERE {cond};", {
            tbl = i(1),
            col = i(2),
            val = i(3),
            cond = i(4),
        })
    ),

    s(
        {
            trig = "delete",
            dscr = {
                "DELETE 行を消す",
                "※ WHERE を書き忘れると全行消える。取り消せない。",
                "  必ず先に SELECT COUNT(*) で件数を確認する。",
            },
        },
        fmt("DELETE FROM {tbl} WHERE {cond};", {
            tbl = i(1),
            cond = i(2),
        })
    ),

    -- ========================================================
    -- 調べる（MySQL の構造確認）
    -- ========================================================

    s(
        {
            trig = "showt",
            dscr = { "SHOW TABLES テーブル一覧" },
        },
        fmt("SHOW TABLES{like};", {
            like = i(1, " LIKE '%'"),
        })
    ),

    s(
        {
            trig = "desc",
            dscr = { "DESCRIBE 列の定義（型・NULL可否・既定値）を見る" },
        },
        fmt("DESCRIBE {tbl};", {
            tbl = i(1),
        })
    ),

    s(
        {
            trig = "showcreate",
            dscr = {
                "SHOW CREATE TABLE 作成文を見る",
                "インデックスや外部キーまで分かる。",
            },
        },
        fmt("SHOW CREATE TABLE {tbl};", {
            tbl = i(1),
        })
    ),
})

-- MySQL / PL/SQL のファイルタイプでも上記のスニペットを使えるようにする
ls.filetype_extend("mysql", { "sql" })
ls.filetype_extend("plsql", { "sql" })
