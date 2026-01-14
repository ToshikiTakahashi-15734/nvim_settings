local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.automatically_reload_config = true
config.font_size = 12.0
config.use_ime = true
config.window_decorations = "RESIZE"
config.hide_tab_bar_if_only_one_tab = true

config.font = wezterm.font("JetBrains Mono", { weight = "Regular" })
config.font_size = 13.0

config.window_frame = {
    inactive_titlebar_bg = "none",
    active_titlebar_bg = "none",
}
config.window_background_gradient = {
    colors = { "#1E1E1E" },
}
config.show_new_tab_button_in_tab_bar = false
config.colors = {
    tab_bar = {
        inactive_tab_edge = "none",
    },
}
local SOLID_LEFT_ARROW = wezterm.nerdfonts.ple_lower_right_triangle
local SOLID_RIGHT_ARROW = wezterm.nerdfonts.ple_upper_left_triangle

wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
    local background = "#5c6d74"
    local foreground = "#FFFFFF"
    local edge_background = "none"
    if tab.is_active then
        background = "#ae8b2d"
        foreground = "#FFFFFF"
    end
    local edge_foreground = background
    local title = "   " .. wezterm.truncate_right(tab.active_pane.title, max_width - 1) .. "   "
    return {
        { Background = { Color = edge_background } },
        { Foreground = { Color = edge_foreground } },
        { Text = SOLID_LEFT_ARROW },
        { Background = { Color = background } },
        { Foreground = { Color = foreground } },
        { Text = title },
        { Background = { Color = edge_background } },
        { Foreground = { Color = edge_foreground } },
        { Text = SOLID_RIGHT_ARROW },
    }
end)

wezterm.on("toggle-opacity", function(window, pane)
    local overrides = window:get_config_overrides() or {}
    if not overrides.window_background_opacity then
        overrides.window_background_opacity = 0.9
        overrides.macos_window_background_blur = 0
    else
        overrides.window_background_opacity = nil
        overrides.macos_window_background_blur = nil
    end
    window:set_config_overrides(overrides)
end)

-- キーバインドを一つのテーブルにまとめる
config.keys = {
    -- 背景透過切り替え
    {
        key = "I",
        mods = "CMD",
        action = wezterm.action.EmitEvent "toggle-opacity",
    },

    -- ウィンドウ切り替え (ALT + n)
    {
        key = 'n',
        mods = 'ALT',
        action = wezterm.action.ActivateWindowRelative(1),
    },

    -- 画面分割 (ペイン)
    {
        key = 'RightArrow', -- 垂直分割 (左右)
        mods = 'ALT|SHIFT',
        action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' },
    },
    {
        key = 'DownArrow', -- 水平分割 (上下)
        mods = 'ALT|SHIFT',
        action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' },
    },

    {
        key = 'LeftArrow',
        mods = 'ALT|CMD',
        action = wezterm.action.ActivatePaneDirection 'Left',
    },
    {
        key = 'RightArrow',
        mods = 'ALT|CMD',
        action = wezterm.action.ActivatePaneDirection 'Right',
    },
    {
        key = 'UpArrow',
        mods = 'ALT|CMD',
        action = wezterm.action.ActivatePaneDirection 'Up',
    },
    {
        key = 'DownArrow',
        mods = 'ALT|CMD',
        action = wezterm.action.ActivatePaneDirection 'Down',
    },

    -- ペインを閉じる (ALT + x)
    {
        key = 'x',
        mods = 'ALT',
        action = wezterm.action.CloseCurrentPane { confirm = false },
    },
}



return config
