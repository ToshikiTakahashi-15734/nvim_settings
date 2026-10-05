-- ============================================================
-- vim-dadbod: Neovim から直接DBに接続する
-- ============================================================
-- できること:
--   ・:Table <名前>  コマンドで中身を表示（名前は <Tab> で補完）
--   ・<leader>dt  テーブル名を絞り込み検索して中身を表示
--   ・<leader>dq  いまのプロジェクト専用のSQL練習ファイルを開く
--   ・<leader>db  サイドバーにDBのテーブル一覧を表示
--   ・<leader>dc  このバッファが使う接続を選び直す（= :DBSelect）
--   ・<leader>de  テーブルを選んでER図を描く（= :ER）
--   ・<leader>S   カーソル位置のクエリをその場で実行
--   ・実DBのスキーマからテーブル名・カラム名を補完
--     （= ターミナルで showdb zinger しなくてよくなる）
--
-- 接続情報は db.setting（Git管理外）に書く。
--
-- どのDBに繋ぐかは、次の順で決まる（resolve_db を参照）:
--   ① そのバッファがすでに繋いでいる接続（b:db）
--   ② DBUI のツリーから開いたバッファの接続
--   ③ プロジェクト名（gitルートのフォルダ名）と同じ接続名
--   ④ このセッションで自分で選んだ接続
-- どれにも当てはまらなければ、その場でDBを選んでもらう。
-- 複数のDBを開いていても、別のDBのテーブル名が混ざらないようにするため、
-- 既定の接続へ黙って落とすことはしない。
-- ============================================================

-- 接続情報を書いておくファイル（Neovim の設定ディレクトリ直下）
local SETTING_FILE = "db.setting"

-- プロジェクト配下に作るSQL置き場のフォルダ名
local SQL_DIR = ".sql"

-- テーブルの中身を覗くときに取ってくる行数。
-- :Table や <leader>dt、サイドバーの List すべてでこの値を使う。
-- （:Table orders 20 のように、その場で行数を指定することもできる）
local ROW_LIMIT = 1000

-- ------------------------------------------------------------
-- 接続先がどの種類のDBかを見分ける
-- ------------------------------------------------------------
-- MySQL と PostgreSQL では、テーブル一覧や列定義の出し方がまったく違う。
--   MySQL      … SHOW TABLES / DESCRIBE テーブル名
--   PostgreSQL … どちらも無い。information_schema を SELECT する
-- URL のスキームで見分けて、それぞれに合った書き方を使う。
local function db_kind(url)
    if not url then
        return "other"
    end
    if url:match("^postgres") then
        return "postgres"
    elseif url:match("^mysql") then
        return "mysql"
    elseif url:match("^sqlite") then
        return "sqlite"
    end
    return "other"
end

-- テーブル一覧を出すクエリ
local function sql_list_tables(url)
    local kind = db_kind(url)
    if kind == "postgres" then
        return "SELECT table_name FROM information_schema.tables"
            .. " WHERE table_schema = 'public' ORDER BY table_name"
    elseif kind == "sqlite" then
        return "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    end
    return "SHOW TABLES"
end

-- 列の定義（型・NULL可否・既定値）を出すクエリ
local function sql_describe(url, name)
    local kind = db_kind(url)
    if kind == "postgres" then
        -- スキーマ付き（public.orders）で渡されることがあるので、
        -- 最後の . から後ろだけをテーブル名として使う
        local bare = name:match("([^%.]+)$") or name
        return "SELECT column_name, data_type, is_nullable, column_default"
            .. " FROM information_schema.columns"
            .. " WHERE table_name = '" .. bare .. "'"
            .. " ORDER BY ordinal_position"
    elseif kind == "sqlite" then
        return "PRAGMA table_info(" .. name .. ")"
    end
    return "DESCRIBE " .. name
end

-- ------------------------------------------------------------
-- db.setting を読み込む
-- ------------------------------------------------------------
-- 「接続名 = URL」の形式を1行ずつ読んでテーブルにする。
-- # から始まる行と空行は無視する。
local function load_settings()
    local path = vim.fn.stdpath("config") .. "/" .. SETTING_FILE
    local dbs = {}

    if vim.fn.filereadable(path) == 0 then
        return dbs
    end

    for _, line in ipairs(vim.fn.readfile(path)) do
        local text = vim.trim(line)
        if text ~= "" and not text:match("^#") then
            local name, url = text:match("^([%w_%-]+)%s*=%s*(.+)$")
            if name and url then
                dbs[name] = vim.trim(url)
            else
                vim.notify(
                    SETTING_FILE .. " の書式が読めない行があります: " .. text,
                    vim.log.levels.WARN
                )
            end
        end
    end

    return dbs
end

-- ------------------------------------------------------------
-- いま作業しているプロジェクトのルートを求める
-- ------------------------------------------------------------
-- 開いているファイルから上に辿って .git を探す。
-- 見つからなければ、いまいるディレクトリを使う。
local function project_root()
    local base = vim.api.nvim_buf_get_name(0)
    if base == "" then
        base = vim.fn.getcwd()
    end
    return vim.fs.root(base, ".git") or vim.fn.getcwd()
end

-- ------------------------------------------------------------
-- URL から接続名を引く
-- ------------------------------------------------------------
-- 画面に出すのは db.setting の接続名（zinger など）だけにする。
-- 一覧に無いURLを出すときは、パスワード部分を伏せ字にする。
local function db_label(url)
    if type(url) ~= "string" or url == "" then
        return "?"
    end
    for name, u in pairs(vim.g.dbs or {}) do
        if u == url then
            return name
        end
    end
    return (url:gsub("://[^@/]*@", "://***@"))
end

-- このセッションで自分で選んだ接続を覚えておく。
-- 手がかりが何も無いときの最後の頼りにする。
local last_picked_url = nil

-- ------------------------------------------------------------
-- DBUI のツリーから開いたバッファの接続を取り出す
-- ------------------------------------------------------------
local function dbui_db()
    local key = vim.b.dbui_db_key_name
    if type(key) ~= "string" or key == "" then
        return nil
    end
    if vim.fn.exists("*db_ui#get_conn_info") == 0 then
        return nil
    end
    local ok, info = pcall(vim.fn["db_ui#get_conn_info"], key)
    if ok and type(info) == "table" and type(info.url) == "string" and info.url ~= "" then
        return info.url
    end
    return nil
end

-- ------------------------------------------------------------
-- このバッファを繋ぐべきDBを決める
-- ------------------------------------------------------------
-- 複数のDBを開いていると「サイドバーで見ているDB」と
-- 「:Table や <leader>dt が使うDB」が食い違いやすい。
-- そこで、バッファがすでに持っている接続を何よりも優先する。
-- 最後まで決まらないときは nil を返し、呼び出し側で選んでもらう
-- （黙って既定のDBに落ちると、別DBのテーブル名が出てしまうため）。
local function resolve_db()
    local dbs = vim.g.dbs or {}

    -- ① このバッファがすでに繋いでいる接続。
    --    DBUI から開いたバッファ、:DBUIFindBuffer で繋ぎ替えたバッファ、
    --    SQLバッファに自動で紐付けた接続がここに入っている。
    if type(vim.b.db) == "string" and vim.b.db ~= "" then
        return vim.b.db
    end

    -- ② DBUI のツリーから開いたバッファ（b:db がまだ無い場合）
    local from_ui = dbui_db()
    if from_ui then
        return from_ui
    end

    -- ③ プロジェクト名（gitルートのフォルダ名）と同じ接続名を探す。
    --    例) ~/develop/zinger で開けば db.setting の zinger に繋がる。
    --    プロジェクトごとに接続を切り替えたいときは、db.setting の
    --    接続名をリポジトリのフォルダ名に合わせておくだけでよい。
    local name = vim.fn.fnamemodify(project_root(), ":t")
    if dbs[name] then
        return dbs[name]
    end

    -- ④ このセッションで自分で選んだ接続
    if last_picked_url and last_picked_url ~= "" then
        return last_picked_url
    end

    return nil
end

-- ------------------------------------------------------------
-- 接続を選んでもらう
-- ------------------------------------------------------------
-- 選んだ接続はこのバッファに覚えさせる（b:db）ので、
-- 以降の :Table / <leader>dt / 補完はすべてそのDBを向く。
local function choose_db(fn)
    local dbs = vim.g.dbs or {}
    local names = vim.tbl_keys(dbs)
    table.sort(names)

    if #names == 0 then
        vim.notify(SETTING_FILE .. " に接続が書かれていません", vim.log.levels.WARN)
        return
    end

    vim.ui.select(names, { prompt = "どのDBに繋ぎますか？" }, function(choice)
        if not choice then
            return
        end
        local url = dbs[choice]
        vim.b.db = url
        last_picked_url = url
        vim.notify("DB: " .. choice .. " に繋ぎました", vim.log.levels.INFO)
        if fn then
            fn(url)
        end
    end)
end

-- 接続が決まっていればそのまま、決まらなければ選んでから処理を続ける
local function with_db(fn)
    local url = resolve_db()
    if url then
        return fn(url)
    end
    choose_db(fn)
end

-- ------------------------------------------------------------
-- プロジェクト専用のSQL練習ファイルを開く
-- ------------------------------------------------------------
-- <プロジェクトルート>/.sql/scratch.sql を開く。
-- 置き場ごと Git の管理外にするので、業務リポジトリの
-- git status を一切汚さない。
-- 接続が決まった状態で呼ばれる本体
local function open_project_sql_for(url)
    local root = project_root()
    local dir = root .. "/" .. SQL_DIR

    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    -- 置き場の中に `*` だけを書いた .gitignore を作る。
    -- これで配下のファイルも .gitignore 自身も無視されるため、
    -- 親リポジトリからは存在しないのと同じ扱いになる。
    local ignore = dir .. "/.gitignore"
    if vim.fn.filereadable(ignore) == 0 then
        vim.fn.writefile({ "*" }, ignore)
    end

    local file = dir .. "/scratch.sql"

    -- 初回だけ、使い方の覚え書きを書いておく
    if vim.fn.filereadable(file) == 0 then
        vim.fn.writefile({
            "-- " .. vim.fn.fnamemodify(root, ":t") .. " のSQL練習用ファイル",
            "--",
            "-- クエリは空行で区切って並べる。<Leader>S を押すと、",
            "-- カーソルがあるクエリだけが実行される。",
            "-- スニペット: select / selw / join / groupby / cte など",
            "",
            sql_list_tables(url) .. ";",
            "",
        }, file)
    end

    vim.cmd("edit " .. vim.fn.fnameescape(file))
end

-- 接続が決まっていなければ、先にDBを選んでもらう
local function open_project_sql()
    with_db(open_project_sql_for)
end

-- ------------------------------------------------------------
-- vim-dadbod を確実に読み込む
-- ------------------------------------------------------------
-- vim-dadbod は遅延読み込みなので、その関数を直接呼ぶ前に
-- 読み込まれていることを保証しておく。
local function ensure_dadbod()
    if vim.fn.exists("*db#adapter#dispatch") == 0 then
        pcall(function()
            require("lazy").load({ plugins = { "vim-dadbod" } })
        end)
    end
end

-- 取得したテーブル一覧を接続ごとに覚えておく。
-- <Tab> 補完のたびにDBへ問い合わせると待たされるため。
-- 一覧を取り直したいときは :Table の第1引数を空にして実行する。
local table_cache = {}

-- ------------------------------------------------------------
-- テーブル一覧をDBから取得する
-- ------------------------------------------------------------
local function fetch_tables(url, force)
    if not force and table_cache[url] then
        return table_cache[url]
    end

    ensure_dadbod()

    local ok, rows = pcall(vim.fn["db#adapter#dispatch"], url, "tables")
    if not ok or type(rows) ~= "table" then
        return nil, tostring(rows)
    end

    -- mysql / psql が出す警告行や、結果表のヘッダー・罫線が
    -- 混ざってくるので取り除く
    local tables = {}
    for _, row in ipairs(rows) do
        local name = vim.trim(row)
        local is_noise = name == ""
            or name:match("^mysql:")            -- パスワードに関する警告
            or name:match("^Tables_in_")        -- SHOW TABLES のヘッダー
            or name:match("^[%+|]")             -- 罫線や表組み
            or name:match("^%-%-+$")            -- psql の区切り線
            or name:match("^%(%d+ rows?%)$")    -- psql の「(26 rows)」
            or name:match("^List of relations") -- psql の \dt の見出し
            or name:match("^Schema%s*|")        -- 同上
            or name == "table_name"             -- SELECT の列見出し
        if not is_noise then
            table.insert(tables, name)
        end
    end

    table_cache[url] = tables
    return tables
end

-- ------------------------------------------------------------
-- クエリを流して結果を表示する
-- ------------------------------------------------------------
-- vim.cmd 経由なので、パスワードを含むURLがコマンド履歴に残らない。
local function run_query(url, query)
    ensure_dadbod()
    vim.cmd(string.format("DB %s %s", url, query))
end

-- ------------------------------------------------------------
-- :Table コマンド ─ テーブルの中身をコマンドで表示する
-- ------------------------------------------------------------
-- 使い方:
--   :Table                      テーブル一覧を表示（キャッシュも取り直す）
--   :Table staff                staff の中身を先頭100行
--   :Table staff 5              先頭5行だけ
--   :Table staff id = 3         条件を付けて絞り込む
--   :Table! staff               列の定義（型・NULL可否・既定値）を見る
--
-- テーブル名は <Tab> で補完できる。部分一致なので、名前の途中を
-- 打ってから <Tab> でも候補が出る。
local function cmd_table_for(url, opts)
    local name = opts.fargs[1]

    -- 引数なし → 一覧を表示しつつ、補完用のキャッシュを取り直す
    if not name then
        fetch_tables(url, true)
        run_query(url, sql_list_tables(url))
        return
    end

    -- : Table! なら列の定義を見る
    if opts.bang then
        run_query(url, sql_describe(url, name))
        return
    end

    -- 2つめ以降の引数は、数字なら行数、それ以外は WHERE の条件とみなす
    local rest = vim.trim(table.concat(opts.fargs, " ", 2))
    local limit = ROW_LIMIT
    local where = nil
    if rest ~= "" then
        if rest:match("^%d+$") then
            limit = tonumber(rest)
        else
            where = rest
        end
    end

    local query = "SELECT * FROM " .. name
    if where then
        query = query .. " WHERE " .. where
    end
    query = query .. string.format(" LIMIT %d", limit)

    run_query(url, query)
end

-- 接続が決まっていなければ、先にDBを選んでもらう
local function cmd_table(opts)
    with_db(function(url)
        cmd_table_for(url, opts)
    end)
end

-- <Tab> を押したときにテーブル名の候補を返す。
-- ここは同期で答えないといけないので、接続が決まらないときは
-- DBを聞きにいかず、黙って候補なしにする（:DBSelect で決められる）。
-- :Table と :ER のテーブル名補完（どちらも第1引数がテーブル名）
local function cmd_table_complete(arg_lead, cmd_line)
    -- テーブル名を打ち終えた後（行数・条件・ホップ数の位置）では候補を出さない
    if cmd_line:match("^%s*%a+!?%s+%S+%s") then
        return {}
    end

    local url = resolve_db()
    if not url then
        return {}
    end

    local tables = fetch_tables(url) or {}
    local matches = {}
    local needle = arg_lead:lower()
    for _, name in ipairs(tables) do
        if needle == "" or name:lower():find(needle, 1, true) then
            table.insert(matches, name)
        end
    end
    return matches
end

-- ------------------------------------------------------------
-- ER図（テーブル同士のつながり）を描く
-- ------------------------------------------------------------
-- 外部キーの定義をDBから取ってきて Mermaid の erDiagram に変換し、
-- .mmd ファイルとして開く。あとは snacks.nvim の image 機能が
-- mmdc（mermaid-cli）を呼んでPNGに焼き、Ghostty の画像プロトコルで
-- そのままバッファに描いてくれる（設定はこのファイルの末尾）。
--
-- DB全体を1枚に描くと毛糸玉になって誰にも読めないので
-- （zinger は 477テーブル・801本の外部キー）、
--   「起点テーブルから外部キーを N 本たどった範囲」
-- だけを切り出して描く。
--
-- 使い方:
--   :ER users        … users の周り（1ホップ）を描く
--   :ER users 2      … 2ホップまで広げる
--   :ER              … テーブルを絞り込み検索して選ぶ
--   <leader>de       … 上と同じ
--   <leader>dt の一覧で <C-e>  … 中身を見ている流れでER図へ

-- 起点テーブルから何ホップ分たどるか（既定値）
local ER_DEPTH = 1

-- 1枚に描くテーブル数の上限。超えたら描く前に確認する
local ER_MAX_NODES = 40

-- ------------------------------------------------------------
-- SQLを流して、結果を「1行1レコード・タブ区切り」で受け取る
-- ------------------------------------------------------------
-- run_query が結果をバッファに出すのに対して、こちらは結果を
-- Lua の値として受け取る。ER図を組み立てるのに中身が要るため。
--
-- vim-dadbod が組み立てた接続コマンドに、DBごとの
-- 「飾りを付けずに出せ」オプションを足して叩く。
--   MySQL      … -B -N   タブ区切り・ヘッダなし
--   PostgreSQL … -t -A -F<TAB>   タプルのみ・整列なし
--   SQLite     … -noheader -separator <TAB>
-- 罫線やヘッダを付けさせないので、結果をそのまま split できる。
local function query_rows(url, sql)
    ensure_dadbod()

    local kind = db_kind(url)
    local target, extra

    if kind == "mysql" then
        target, extra = "interactive", { "-B", "-N", "-e", sql }
    elseif kind == "postgres" then
        target, extra = "interactive", { "-t", "-A", "-F", "\t", "-c", sql }
    elseif kind == "sqlite" then
        target, extra = "command", { "-noheader", "-separator", "\t", sql }
    else
        return nil, "ER図は MySQL / PostgreSQL / SQLite にのみ対応しています"
    end

    local ok, argv = pcall(vim.fn["db#adapter#dispatch"], url, target)
    if not ok or type(argv) ~= "table" then
        return nil, tostring(argv)
    end

    local cmd = vim.list_extend(vim.deepcopy(argv), extra)
    local lines = vim.fn["db#systemlist"](cmd)

    local rows = {}
    for _, line in ipairs(lines) do
        -- mysql は -p でパスワードを渡すと必ず警告を1行吐く
        if vim.trim(line) ~= "" and not line:match("^mysql: %[Warning%]") then
            table.insert(rows, vim.split(line, "\t", { plain = true }))
        end
    end
    return rows
end

-- ------------------------------------------------------------
-- 外部キーの一覧を出すクエリ
-- ------------------------------------------------------------
-- 「子テーブル / 子の列 / 親テーブル / 親の列」の4列を返す。
local function sql_foreign_keys(url)
    local kind = db_kind(url)

    if kind == "postgres" then
        return table.concat({
            "SELECT tc.table_name, kcu.column_name,",
            "       ccu.table_name, ccu.column_name",
            "FROM information_schema.table_constraints tc",
            "JOIN information_schema.key_column_usage kcu",
            "  ON kcu.constraint_name = tc.constraint_name",
            " AND kcu.constraint_schema = tc.constraint_schema",
            "JOIN information_schema.constraint_column_usage ccu",
            "  ON ccu.constraint_name = tc.constraint_name",
            " AND ccu.constraint_schema = tc.constraint_schema",
            "WHERE tc.constraint_type = 'FOREIGN KEY'",
            "  AND tc.table_schema = 'public'",
            "ORDER BY tc.table_name",
        }, "\n")
    elseif kind == "sqlite" then
        -- SQLite には情報スキーマが無い。PRAGMA をテーブル関数として
        -- 呼べる（3.16以降）ので、それを全テーブルに JOIN する。
        return table.concat({
            'SELECT m.name, p."from", p."table", p."to"',
            "FROM sqlite_master m",
            "JOIN pragma_foreign_key_list(m.name) p",
            "WHERE m.type = 'table'",
            "ORDER BY m.name",
        }, "\n")
    end

    return table.concat({
        "SELECT TABLE_NAME, COLUMN_NAME,",
        "       REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME",
        "FROM information_schema.KEY_COLUMN_USAGE",
        "WHERE TABLE_SCHEMA = DATABASE()",
        "  AND REFERENCED_TABLE_NAME IS NOT NULL",
        "ORDER BY TABLE_NAME",
    }, "\n")
end

-- ------------------------------------------------------------
-- 起点テーブルの列定義を出すクエリ
-- ------------------------------------------------------------
-- 「列名 / 型 / PK か FK か」の3列を返す。
local function sql_er_columns(url, name)
    local kind = db_kind(url)
    -- スキーマ付き（public.orders）で渡されることがあるので、
    -- 最後の . から後ろだけをテーブル名として使う
    local bare = name:match("([^%.]+)$") or name

    if kind == "postgres" then
        return table.concat({
            "SELECT c.column_name, c.data_type,",
            "       CASE WHEN pk.column_name IS NOT NULL THEN 'PK' ELSE '' END",
            "FROM information_schema.columns c",
            "LEFT JOIN (",
            "    SELECT kcu.column_name",
            "    FROM information_schema.table_constraints tc",
            "    JOIN information_schema.key_column_usage kcu",
            "      ON kcu.constraint_name = tc.constraint_name",
            "    WHERE tc.constraint_type = 'PRIMARY KEY'",
            "      AND tc.table_name = '" .. bare .. "'",
            ") pk ON pk.column_name = c.column_name",
            "WHERE c.table_schema = 'public'",
            "  AND c.table_name = '" .. bare .. "'",
            "ORDER BY c.ordinal_position",
        }, "\n")
    elseif kind == "sqlite" then
        return "SELECT name, type, CASE WHEN pk > 0 THEN 'PK' ELSE '' END"
            .. " FROM pragma_table_info('" .. bare .. "')"
    end

    return table.concat({
        "SELECT COLUMN_NAME, DATA_TYPE,",
        "       CASE COLUMN_KEY WHEN 'PRI' THEN 'PK'",
        "                       WHEN 'MUL' THEN 'FK' ELSE '' END",
        "FROM information_schema.COLUMNS",
        "WHERE TABLE_SCHEMA = DATABASE()",
        "  AND TABLE_NAME = '" .. bare .. "'",
        "ORDER BY ORDINAL_POSITION",
    }, "\n")
end

-- 外部キーの一覧を接続ごとに覚えておく。
-- 1枚描くたびに数百行のクエリを投げ直さないため。
-- 取り直したいときは :ER! を使う。
local fk_cache = {}

-- ------------------------------------------------------------
-- 外部キーの一覧をDBから取得する
-- ------------------------------------------------------------
local function fetch_foreign_keys(url, force)
    if not force and fk_cache[url] then
        return fk_cache[url]
    end

    local rows, err = query_rows(url, sql_foreign_keys(url))
    if not rows then
        return nil, err
    end

    local fks = {}
    for _, row in ipairs(rows) do
        local child, column, parent = row[1], row[2], row[3]
        if child and parent and child ~= "" and parent ~= "" then
            table.insert(fks, {
                child = child,
                column = column or "",
                parent = parent,
            })
        end
    end

    fk_cache[url] = fks
    return fks
end

-- ------------------------------------------------------------
-- 起点テーブルから外部キーを N 本たどって、仲間を集める
-- ------------------------------------------------------------
-- 外部キーは「子→親」の向きを持つが、たどるときは向きを無視して
-- 両方向に広げる。orders から order_items（子）にも
-- customers（親）にも行きたいため。
local function collect_related(fks, root, depth)
    local neighbours = {}
    local function link(from, to)
        neighbours[from] = neighbours[from] or {}
        table.insert(neighbours[from], to)
    end
    for _, fk in ipairs(fks) do
        link(fk.child, fk.parent)
        link(fk.parent, fk.child)
    end

    local members = { [root] = true }
    local order = { root }
    local frontier = { root }

    for _ = 1, depth do
        local next_frontier = {}
        for _, name in ipairs(frontier) do
            for _, neighbour in ipairs(neighbours[name] or {}) do
                if not members[neighbour] then
                    members[neighbour] = true
                    table.insert(order, neighbour)
                    table.insert(next_frontier, neighbour)
                end
            end
        end
        frontier = next_frontier
    end

    return members, order
end

-- Mermaid が名前として受け付けるのは英数字と _ だけ。
-- 記号を含むテーブル名は _ に置き換える。
local function mermaid_name(name)
    local safe = name:gsub("[^%w_]", "_")
    return safe
end

-- ------------------------------------------------------------
-- Mermaid の erDiagram を組み立てる
-- ------------------------------------------------------------
-- 起点テーブルだけ列を並べ、周りはテーブル名とつながりだけ描く。
-- 全部の列を描くと1ホップでも画面に収まらなくなるため。
local function render_er(root, columns, fks, members, depth)
    local lines = {
        "%% " .. root .. " を起点に外部キーを " .. depth .. " 本たどった範囲",
        "erDiagram",
    }

    if columns and #columns > 0 then
        table.insert(lines, ("    %s {"):format(mermaid_name(root)))
        for _, col in ipairs(columns) do
            local name = col[1] or ""
            local ctype = col[2] or "unknown"
            local key = col[3] or ""
            if name ~= "" then
                -- 型名の varchar(255) や character varying は
                -- そのままだと Mermaid が構文エラーにするので均す
                ctype = ctype:gsub("[^%w_]", "_")
                local col = ("%s %s %s"):format(ctype, mermaid_name(name), key)
                table.insert(lines, "        " .. vim.trim(col))
            end
        end
        table.insert(lines, "    }")
    end

    -- 同じテーブルの組を結ぶ外部キーが複数あるとき（複合キーなど）は
    -- 1本の線にまとめ、列名をカンマでつなげて添える
    local seen = {}
    local pairs_order = {}
    for _, fk in ipairs(fks) do
        if members[fk.child] and members[fk.parent] then
            local key = fk.parent .. "\0" .. fk.child
            if not seen[key] then
                seen[key] = { parent = fk.parent, child = fk.child, columns = {} }
                table.insert(pairs_order, key)
            end
            table.insert(seen[key].columns, fk.column)
        end
    end

    for _, key in ipairs(pairs_order) do
        local rel = seen[key]
        table.insert(lines, ('    %s ||--o{ %s : "%s"'):format(
            mermaid_name(rel.parent),
            mermaid_name(rel.child),
            table.concat(rel.columns, ", ")
        ))
    end

    return lines
end

-- ------------------------------------------------------------
-- 図を書き出す場所を用意する
-- ------------------------------------------------------------
-- SQL練習ファイルと同じ <プロジェクトルート>/.sql/ に置く。
-- 中の .gitignore が配下を丸ごと無視するので、
-- 業務リポジトリの git status は汚れない。
local function ensure_er_dir()
    local dir = project_root() .. "/" .. SQL_DIR

    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    local ignore = dir .. "/.gitignore"
    if vim.fn.filereadable(ignore) == 0 then
        vim.fn.writefile({ "*" }, ignore)
    end

    return dir
end

-- ------------------------------------------------------------
-- ER図を描いて開く（接続が決まった状態で呼ばれる本体）
-- ------------------------------------------------------------
local function er_diagram_for(url, name, depth, force)
    depth = depth or ER_DEPTH

    -- mmdc が無いと .mmd を開いても絵にならず、ただの文字列が出る。
    -- 先に気づけるよう、ここで案内しておく。
    if vim.fn.executable("mmdc") == 0 then
        vim.notify(
            "ER図を絵にするには mermaid-cli が必要です:\n"
            .. "  npm install -g @mermaid-js/mermaid-cli\n"
            .. "（画像のサイズ取得に ImageMagick も要ります: brew install imagemagick）",
            vim.log.levels.WARN
        )
    end

    local fks, err = fetch_foreign_keys(url, force)
    if not fks then
        vim.notify(
            ("[%s] 外部キーを取得できませんでした: %s"):format(db_label(url), err or ""),
            vim.log.levels.ERROR
        )
        return
    end

    if #fks == 0 then
        vim.notify(
            ("[%s] このDBには外部キーが1本もありません。ER図は描けません"):format(db_label(url)),
            vim.log.levels.WARN
        )
        return
    end

    local members, order = collect_related(fks, name, depth)

    if #order == 1 then
        vim.notify(
            ("[%s] %s には外部キーのつながりがありません"):format(db_label(url), name),
            vim.log.levels.WARN
        )
        return
    end

    -- 広げすぎると mmdc が延々と唸った末に読めない絵を吐くので、
    -- 描く前に一度止まって訊く
    if #order > ER_MAX_NODES then
        local answer = vim.fn.confirm(
            ("%s を %d ホップ広げると %d テーブルになります。描きますか？")
                :format(name, depth, #order),
            "&描く\n&やめる",
            2
        )
        if answer ~= 1 then
            return
        end
    end

    local columns = query_rows(url, sql_er_columns(url, name))
    local lines = render_er(name, columns, fks, members, depth)

    local file = ("%s/er_%s_%d.mmd"):format(ensure_er_dir(), name:gsub("[^%w_]", "_"), depth)
    vim.fn.writefile(lines, file)

    -- edit! で開き直す。同じファイルを描き直したとき、
    -- 古い絵が残ったままにならないようにするため。
    vim.cmd("edit! " .. vim.fn.fnameescape(file))

    vim.notify(
        ("[%s] %s の周り %d テーブルを描きました"):format(db_label(url), name, #order),
        vim.log.levels.INFO
    )
end

-- ------------------------------------------------------------
-- ER図を描くテーブルを絞り込み検索して選ぶ
-- ------------------------------------------------------------
local function pick_er_table_for(url)
    local has_telescope, pickers = pcall(require, "telescope.pickers")
    if not has_telescope then
        vim.notify("telescope.nvim が必要です", vim.log.levels.ERROR)
        return
    end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local tables, err = fetch_tables(url)
    if not tables or #tables == 0 then
        vim.notify(
            ("[%s] テーブル一覧を取得できませんでした: %s"):format(db_label(url), err or ""),
            vim.log.levels.ERROR
        )
        return
    end

    pickers.new({}, {
        prompt_title = ("[%s] ER図を描くテーブル  <CR>1ホップ  <C-d>2ホップ")
            :format(db_label(url)),
        finder = finders.new_table({ results = tables }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(bufnr, map)
            local function draw(depth)
                local entry = action_state.get_selected_entry()
                local name = entry and entry[1] or nil
                actions.close(bufnr)
                if name then
                    er_diagram_for(url, name, depth)
                end
            end

            actions.select_default:replace(function()
                draw(1)
            end)

            map({ "i", "n" }, "<C-d>", function()
                draw(2)
            end)

            return true
        end,
    }):find()
end

-- 接続が決まっていなければ、先にDBを選んでもらう
local function pick_er_table()
    with_db(pick_er_table_for)
end

-- :ER コマンドの中身
--   :ER            テーブルを選ぶところから
--   :ER users      users の周りを1ホップ
--   :ER users 2    2ホップまで
--   :ER!           外部キーの一覧を取り直してから描く
local function cmd_er(opts)
    local name = opts.fargs[1]
    local depth = tonumber(opts.fargs[2]) or ER_DEPTH

    with_db(function(url)
        if not name or name == "" then
            pick_er_table_for(url)
        else
            er_diagram_for(url, name, depth, opts.bang)
        end
    end)
end


-- ------------------------------------------------------------
-- テーブル名を絞り込み検索して、中身を表示する
-- ------------------------------------------------------------
local function pick_table_for(url)
    local has_telescope, pickers = pcall(require, "telescope.pickers")
    if not has_telescope then
        vim.notify("telescope.nvim が必要です", vim.log.levels.ERROR)
        return
    end
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local tables, err = fetch_tables(url)
    if not tables or #tables == 0 then
        vim.notify(
            ("[%s] テーブル一覧を取得できませんでした: %s"):format(db_label(url), err or ""),
            vim.log.levels.ERROR
        )
        return
    end

    local function run(query)
        run_query(url, query)
    end

    pickers.new({}, {
        prompt_title = ("[%s] テーブル %d件  <CR>中身  <C-d>列定義  <C-t>件数  <C-e>ER図  <C-y>名前を挿入")
            :format(db_label(url), #tables),
        finder = finders.new_table({ results = tables }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(bufnr, map)
            local function selected()
                local entry = action_state.get_selected_entry()
                return entry and entry[1] or nil
            end

            -- <CR> 中身を表示する
            actions.select_default:replace(function()
                local name = selected()
                actions.close(bufnr)
                if name then
                    run(("SELECT * FROM %s LIMIT %d"):format(name, ROW_LIMIT))
                end
            end)

            -- <C-d> 列の定義（型・NULL可否・既定値）を見る
            map({ "i", "n" }, "<C-d>", function()
                local name = selected()
                actions.close(bufnr)
                if name then
                    run(sql_describe(url, name))
                end
            end)

            -- <C-t> 件数を数える
            map({ "i", "n" }, "<C-t>", function()
                local name = selected()
                actions.close(bufnr)
                if name then
                    run(("SELECT COUNT(*) AS cnt FROM %s"):format(name))
                end
            end)

            -- <C-e> このテーブルを起点にER図を描く
            map({ "i", "n" }, "<C-e>", function()
                local name = selected()
                actions.close(bufnr)
                if name then
                    er_diagram_for(url, name)
                end
            end)

            -- <C-y> テーブル名だけをカーソル位置に挿し込む
            --        （SQLを書いている途中に名前を思い出したいとき）
            map({ "i", "n" }, "<C-y>", function()
                local name = selected()
                actions.close(bufnr)
                if name then
                    vim.api.nvim_put({ name }, "c", true, true)
                end
            end)

            return true
        end,
    }):find()
end

-- 接続が決まっていなければ、先にDBを選んでもらう
local function pick_table()
    with_db(pick_table_for)
end

return {
    -- DB接続の土台。UIと補完がこれに依存する
    {
        "tpope/vim-dadbod",
        -- :DB を直接叩いたときにも読み込まれるようコマンドを登録しておく
        -- （登録しないと :DB が未定義のままで E464 になる）
        cmd = { "DB", "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
        init = function()
            -- MySQL のクライアントコマンドを Neovim 側で PATH に通す。
            --
            -- vim-dadbod は接続に外部の `mysql` コマンドを使うが、
            -- Homebrew の mysql-client は keg-only のため自動で PATH に
            -- 入らない。シェルの設定に頼ると
            --   ・ターミナルを開き直すまで反映されない
            --   ・GUI から起動した Neovim では永久に反映されない
            -- という取りこぼしが出るので、ここで自力で通しておく。
            local candidates = {
                "/opt/homebrew/opt/mysql-client/bin", -- Apple Silicon
                "/usr/local/opt/mysql-client/bin",    -- Intel Mac
                "/opt/homebrew/opt/mysql/bin",        -- mysql 本体を入れている場合
            }
            for _, dir in ipairs(candidates) do
                local path = vim.env.PATH or ""
                if vim.fn.isdirectory(dir) == 1 and not path:find(dir, 1, true) then
                    vim.env.PATH = dir .. ":" .. path
                end
            end

            -- クエリ結果の後始末をする。
            --
            -- DBExecutePost は「結果をバッファに読み込んだ後、完了メッセージを
            -- echo する直前」に発火するフック。ここで2つの厄介を片付ける。
            vim.api.nvim_create_autocmd("User", {
                pattern = "*/DBExecutePost",
                callback = function(args)
                    -- ① mysql の警告行を結果から取り除く
                    --
                    -- mysql コマンドは -p でパスワードを渡すと必ず
                    --   mysql: [Warning] Using a password on the command line...
                    -- を1行吐く。これが結果の先頭に混ざると、dbout の
                    -- 折りたたみ判定（罫線 +--- の位置を見ている）がずれて
                    -- 中身が畳まれたまま見えなくなる。
                    -- セルの取得や外部キージャンプも行番号がずれて壊れる。
                    local path = (args.match or ""):gsub("/DBExecutePost$", "")
                    local bufnr = path ~= "" and vim.fn.bufnr(path) or -1

                    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
                        -- 先頭に連続する警告行を数える
                        local head = vim.api.nvim_buf_get_lines(bufnr, 0, 5, false)
                        local drop = 0
                        for _, line in ipairs(head) do
                            if line:match("^mysql: %[Warning%]") then
                                drop = drop + 1
                            else
                                break
                            end
                        end

                        if drop > 0 then
                            -- 結果バッファは書き換え禁止なので一時的に外す
                            local modifiable = vim.bo[bufnr].modifiable
                            vim.bo[bufnr].modifiable = true
                            vim.api.nvim_buf_set_lines(bufnr, 0, drop, false, {})
                            vim.bo[bufnr].modifiable = modifiable
                            vim.bo[bufnr].modified = false

                        end

                        -- 結果が畳まれて見えなくならないよう、
                        -- 表示中のウィンドウの折りたたみを切る
                        for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
                            vim.wo[win].foldenable = false
                        end
                    end

                    -- ② 長い完了メッセージを消す
                    --
                    -- dadbod はこの直後に
                    --   DB: Query '/var/folders/.../5.dbout' finished in 0.031s
                    -- という80文字超のメッセージを echo する。コマンドライン
                    -- 1行に収まらないと hit-enter プロンプトが出て、実行する
                    -- たびに Enter を押す手間になる。抑制する設定が無いので
                    -- 出た直後に消す（メッセージ履歴には残る）。
                    vim.schedule(function()
                        vim.api.nvim_echo({ { "" } }, false, {})
                    end)
                end,
            })
        end,
    },

    -- サイドバーUI。テーブル一覧をツリーで見て、クエリを実行できる
    {
        "kristijanhusak/vim-dadbod-ui",
        dependencies = { "tpope/vim-dadbod" },
        cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
        -- SQLファイルを開いた時点で読み込む。
        -- これを入れないと <Leader>S（クエリ実行）などのキーマップが
        -- 効かない（キーマップは dadbod-ui の ftplugin/sql.vim が張るため）
        ft = { "sql", "mysql", "plsql" },
        keys = {
            { "<leader>db", "<cmd>DBUIToggle<cr>", desc = "DB: サイドバーを開閉" },
            { "<leader>dq", open_project_sql, desc = "DB: このプロジェクトのSQL練習ファイルを開く" },
            { "<leader>dt", pick_table, desc = "DB: テーブルを絞り込み検索して中身を見る" },
            { "<leader>de", pick_er_table, desc = "DB: テーブルを選んでER図を描く" },
            {
                "<leader>dc",
                function()
                    choose_db()
                end,
                desc = "DB: このバッファが使う接続を選び直す",
            },
        },
        init = function()
            -- 接続情報を db.setting から読み込む
            vim.g.dbs = load_settings()

            vim.g.db_ui_use_nerd_fonts = 1
            vim.g.db_ui_win_position = "left"
            vim.g.db_ui_winwidth = 35
            -- 保存したクエリの置き場所（設定リポジトリを汚さない場所にする）
            vim.g.db_ui_save_location = vim.fn.stdpath("data") .. "/db_ui_queries"
            -- :w した瞬間に実行されると事故るので切っておく（実行は <leader>S）
            vim.g.db_ui_execute_on_save = 0

            -- クエリ結果を折りたたまずに全部表示する。
            --
            -- vim-dadbod-ui は結果画面(dbout)に
            --   foldmethod=expr foldexpr=db_ui#dbout#foldexpr(v:lnum)
            -- を設定し、罫線(+---)を境界にして結果を折りたたむ。
            -- 複数クエリの結果を一覧するための機能で、普段は末尾の zo で
            -- 自動的に開かれるのだが、1クエリずつ試す使い方では
            -- 「+-- 31 lines:」と畳まれて中身が見えない事故になりやすい。
            -- ここでは常に開いた状態にしておく。
            -- 結果バッファを表示しているウィンドウの折りたたみを切る
            local function unfold_result(bufnr)
                for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
                    -- カレントウィンドウが結果画面から離れていても
                    -- 当たるよう、ウィンドウを直接指定する
                    vim.wo[win].foldenable = false
                end
            end

            vim.api.nvim_create_autocmd("FileType", {
                pattern = "dbout",
                callback = function(args)
                    unfold_result(args.buf)
                end,
            })

            -- 結果バッファがウィンドウに入った時点でも念のため切る
            vim.api.nvim_create_autocmd("BufWinEnter", {
                pattern = "*.dbout",
                callback = function(args)
                    unfold_result(args.buf)
                end,
            })

            -- サイドバーの List で取ってくる行数を増やす。
            --
            -- vim-dadbod-ui の List は、既定では LIMIT 200 が埋め込まれている
            -- （autoload/db_ui/table_helpers.vim にDBの種類ごとに書いてある）。
            -- ここで List だけを上書きすると、Columns や Indexes といった
            -- 他のヘルパーは元の定義がそのまま残る。
            --
            -- {optional_schema} と {table} は dadbod-ui が実際の名前に
            -- 置き換えてくれるので、そのまま書いておく。
            vim.g.db_ui_table_helpers = {
                postgresql = { List = ('select * from {optional_schema}"{table}" LIMIT %d'):format(ROW_LIMIT) },
                mysql      = { List = ('SELECT * from {optional_schema}`{table}` LIMIT %d'):format(ROW_LIMIT) },
                mariadb    = { List = ('SELECT * from {optional_schema}`{table}` LIMIT %d'):format(ROW_LIMIT) },
                sqlite     = { List = ('SELECT * FROM "{table}" LIMIT %d'):format(ROW_LIMIT) },
            }

            -- ヘルパーが用意されていない種類のDBで使われる既定のクエリ
            vim.g.db_ui_default_query = ('SELECT * FROM "{table}" LIMIT %d;'):format(ROW_LIMIT)

            -- サイドバーでテーブルを開いたとき、中身を自動で表示する。
            --
            -- 既定ではクエリが書かれたバッファが開くだけで、そこから
            -- <Leader>S を押さないと結果が見られない。これを 1 にすると
            -- 開いた時点で実行までやってくれる。
            -- MySQL のヘルパーは List（SELECT * ... LIMIT 200）が先頭に
            -- 並んでいるので、テーブル名で <CR> → List で <CR> の
            -- 2回で中身が出る。
            vim.g.db_ui_auto_execute_table_helpers = 1

            -- :Table コマンドを登録する
            vim.api.nvim_create_user_command("Table", cmd_table, {
                bang = true,
                nargs = "*",
                complete = cmd_table_complete,
                desc = "テーブルの中身を表示（:Table <名前> [行数|条件]、! で列定義）",
            })

            -- :ER コマンドを登録する
            vim.api.nvim_create_user_command("ER", cmd_er, {
                bang = true,
                nargs = "*",
                complete = cmd_table_complete,
                desc = "ER図を描く（:ER <名前> [ホップ数]、! で外部キーを取り直す）",
            })

            -- :DBSelect コマンドを登録する。
            --
            -- 接続は「バッファが繋いでいるDB → プロジェクト名」の順に
            -- 自動で決まるが、その推測が意図と違うときはこれで選び直す。
            vim.api.nvim_create_user_command("DBSelect", function()
                choose_db()
            end, {
                desc = "このバッファが使うDB接続を選び直す",
            })

            -- 小文字の :table でも打てるようにする。
            --
            -- Vim のユーザー定義コマンドは大文字始まりが必須なので
            -- （小文字だと E183 になる）、コマンドライン略語で読み替える。
            -- コマンドラインの先頭でちょうど "table" と打ったときだけ
            -- 置き換えるため、:%s/table/... のような他の用途は壊さない。
            vim.cmd(table.concat({
                "cnoreabbrev <expr> table",
                "(getcmdtype() ==# ':' && getcmdline() ==# 'table')",
                "? 'Table' : 'table'",
            }, " "))
        end,
    },

    -- 実DBのスキーマからテーブル名・カラム名を補完する
    {
        "kristijanhusak/vim-dadbod-completion",
        dependencies = { "tpope/vim-dadbod" },
        ft = { "sql", "mysql", "plsql" },
        config = function()
            -- SQLバッファを開いたときの下準備
            local function setup_sql_buffer()
                -- ① 接続先を紐付ける
                --
                -- 補完はバッファ変数 b:db を見て「どのDBのスキーマか」を
                -- 判断している。ただの .sql ファイルを開いただけでは b:db が
                -- 空なので、候補が1つも出てこない。
                -- そこで resolve_db が決めたDBを自動で紐付けておく。
                -- 別のDBに切り替えたいときは :DBSelect（<leader>dc）か
                -- :DBUIFindBuffer を使う。
                if not vim.b.db or vim.b.db == "" then
                    local url = resolve_db()
                    if url then
                        vim.b.db = url
                    end
                end

                -- ② 補完ソースを差し替える
                --
                -- 実DBのスキーマとスニペットを最優先にし、
                -- それらに候補が無いときだけバッファ内の単語を出す。
                local ok, cmp = pcall(require, "cmp")
                if not ok then
                    return
                end
                cmp.setup.buffer({
                    sources = cmp.config.sources({
                        { name = "vim-dadbod-completion" },
                        { name = "luasnip" },
                    }, {
                        { name = "buffer" },
                    }),
                })

                -- ③ クエリ実行のキーマップを張り直す
                --
                -- <Leader>S は dadbod-ui が ftplugin で用意してくれるが、
                -- その中身（<Plug>(DBUI_ExecuteQuery)）は DBUI 経由で開いた
                -- バッファにしか存在しない。普通に開いた .sql ファイルでは
                -- 押しても無反応になってしまう。
                -- そこで、どちらのバッファでも同じキーで動くようにする。
                vim.keymap.set("n", "<leader>S", function()
                    if vim.fn.maparg("<Plug>(DBUI_ExecuteQuery)", "n") ~= "" then
                        -- DBUI 経由のバッファ → dadbod-ui の実行機能に任せる
                        local keys = vim.api.nvim_replace_termcodes(
                            "<Plug>(DBUI_ExecuteQuery)", true, true, true
                        )
                        vim.api.nvim_feedkeys(keys, "m", false)
                    else
                        -- 普通の .sql ファイル → カーソルがある段落を実行する。
                        -- クエリを空行で区切って並べておけば、いま
                        -- カーソルがあるクエリだけが走る。
                        vim.cmd("'{,'}DB")
                    end
                end, { buffer = true, desc = "SQL: カーソル位置のクエリを実行" })

                -- 選択した範囲だけを実行する（v で選んでから <Leader>S）
                vim.keymap.set("v", "<leader>S", ":DB<cr>", {
                    buffer = true,
                    desc = "SQL: 選択範囲を実行",
                })
            end

            vim.api.nvim_create_autocmd("FileType", {
                pattern = { "sql", "mysql", "plsql" },
                callback = setup_sql_buffer,
            })

            -- ft トリガーで読み込まれた「今まさに開いたバッファ」にも適用する
            setup_sql_buffer()
        end,
    },
    -- ER図（.mmd）をバッファの中に絵として表示する
    --
    -- snacks.nvim は claudecode.nvim の依存として元から入っている。
    -- その image 機能は、拡張子が formats に載っているファイルを開くと
    --   ・.mmd → mmdc で PNG に焼く
    --   ・PNG を Kitty 画像プロトコルで端末に描く
    -- という段取りを自動でやってくれる（Ghostty はこの規格に対応している）。
    -- 既定の formats に .mmd は入っていないので、ここで足す。
    --
    -- 必要な外部コマンド:
    --   npm install -g @mermaid-js/mermaid-cli   （mmdc 本体）
    --   brew install imagemagick                 （画像サイズの取得に使う）
    -- 入っているかどうかは :checkhealth snacks で確かめられる。
    {
        "folke/snacks.nvim",
        -- image は「ファイルを開いた瞬間」に割り込む必要があるので、
        -- 遅延読み込みにはできない
        priority = 1000,
        lazy = false,
        opts = {
            image = {
                enabled = true,
                formats = {
                    "png", "jpg", "jpeg", "gif", "bmp", "webp",
                    "tiff", "heic", "avif", "pdf",
                    "mmd", -- Mermaid（ER図はこれで開く）
                },
            },
        },
    },
}
