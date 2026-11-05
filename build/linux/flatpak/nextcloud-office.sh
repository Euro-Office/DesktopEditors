#!/bin/sh
# Flatpak counterpart of /usr/bin/nextcloud-office-nextcloudoffice from the deb.
APP_PATH=/app/nextcloud-office

export LD_LIBRARY_PATH=$APP_PATH:$APP_PATH/converter${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export LD_PRELOAD=$APP_PATH/libcef.so
# The GTK file chooser only sees the sandbox; the portal sees the host.
exec $APP_PATH/DesktopEditors --xdg-desktop-portal "$@"
