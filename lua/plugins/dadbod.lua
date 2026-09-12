-- ============================================================
-- vim-dadbod: Neovim から直接DBに接続する
-- ============================================================
-- できること:
--   ・:Table <名前>  コマンドで中身を表示（名前は <Tab> で補完）
--   ・<leader>dt  テーブル名を絞り込み検索して中身を表示
--   ・<leader>dq  いまのプロジェクト専用のSQL練習ファイルを開く
--   ・<leader>db  サイドバーにDBのテーブル一覧を表示
--   ・<leader>S   カーソル位置のクエリをその場で実行
--   ・実DBのスキーマからテーブル名・カラム名を補完
--     （= ターミナルで showdb zinger しなくてよくなる）
--
-- 接続情報は db.setting（Git管理外）に書く。
-- ============================================================

-- 接続情報を書いておくファイル（Neovim の設定ディレクトリ直下）
local SETTING_FILE = "db.setting"

-- プロジェクト名に対応する接続が見つからなかったときに使う接続名
local FALLBACK_DB = "zinger"

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
-- このバッファを繋ぐべきDBを決める
-- ------------------------------------------------------------
local function resolve_db()
    local dbs = vim.g.dbs or {}

    -- ① プロジェクト名（gitルートのフォルダ名）と同じ接続名を探す。
    --    例) ~/develop/zinger で開けば db.setting の zinger に繋がる。
    --    プロジェクトごとに接続を切り替えたいときは、db.setting の
    --    接続名をリポジトリのフォルダ名に合わせておくだけでよい。
    local name = vim.fn.fnamemodify(project_root(), ":t")
    if dbs[name] then
        return dbs[name]
    end

    -- ② 見つからなければ既定の接続
    if dbs[FALLBACK_DB] then
        return dbs[FALLBACK_DB]
    end

    -- ③ それも無ければ db.setting の先頭の接続
    local _, first = next(dbs)
    return first
end

-- ------------------------------------------------------------
-- プロジェクト専用のSQL練習ファイルを開く
-- ------------------------------------------------------------
-- <プロジェクトルート>/.sql/scratch.sql を開く。
-- 置き場ごと Git の管理外にするので、業務リポジトリの
-- git status を一切汚さない。
local function open_project_sql()
    local root = project_root()
    local url = resolve_db()
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
local function cmd_table(opts)
    local url = resolve_db()
    if not url then
        vim.notify(SETTING_FILE .. " に接続が書かれていません", vim.log.levels.WARN)
        return
    end

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

-- <Tab> を押したときにテーブル名の候補を返す
local function cmd_table_complete(arg_lead, cmd_line)
    -- テーブル名を打ち終えた後（行数や条件の位置）では候補を出さない
    if cmd_line:match("^%s*Table!?%s+%S+%s") then
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
-- テーブル名を絞り込み検索して、中身を表示する
-- ------------------------------------------------------------
local function pick_table()
    local url = resolve_db()
    if not url then
        vim.notify(SETTING_FILE .. " に接続が書かれていません", vim.log.levels.WARN)
        return
    end

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
        vim.notify("テーブル一覧を取得できませんでした: " .. (err or ""), vim.log.levels.ERROR)
        return
    end

    local function run(query)
        run_query(url, query)
    end

    pickers.new({}, {
        prompt_title = ("テーブル %d件  <CR>中身  <C-d>列定義  <C-t>件数  <C-y>名前を挿入")
            :format(#tables),
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
                -- そこでプロジェクトに対応するDBを自動で紐付けておく。
                -- 別のDBに切り替えたいときは :DBUIFindBuffer を使う。
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
}
