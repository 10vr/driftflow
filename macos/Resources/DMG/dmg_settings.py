# dmgbuild settings for Driftflow's installer disk image (used by release.sh):
#   dmgbuild -s Resources/DMG/dmg_settings.py -D app=<path to Driftflow.app> "Driftflow" <output.dmg>
# The window shows Driftflow and an Applications shortcut on the background from
# make_background.py, positioned to match its arrow.
import os.path

application = defines.get("app", "build.noindex/Driftflow.app")  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else "Resources/DMG"

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = application + "/Contents/Resources/AppIcon.icns"  # the mounted volume's icon
background = os.path.join("Resources", "DMG", "background.tiff")
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {appname: (170, 205), "Applications": (470, 205)}
