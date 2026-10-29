# dmgbuild settings for Saywell's installer window (used by Scripts/package.sh):
# the app and an Applications shortcut on a designed background, drag to install.
# Icon positions match DMGArt.swift, which draws the background around them.
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]              # the disk's icon when mounted
background = defines["background"]  # 660x440 (+@2x) TIFF
format = "ULFO"                     # LZFSE-compressed, read-only
filesystem = "HFS+"
window_rect = ((200, 140), (660, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 112
text_size = 13
hide_extensions = ["Saywell.app"]
icon_locations = {"Saywell.app": (170, 200), "Applications": (490, 200)}
