//! Folder picker.
//!
//! KDE's portal uses a breadcrumb-only dialog for `directory=true` unless the
//! request also carries a `choices` entry. A blank choice is enough to get the
//! same path field as the file dialog. File picks stay on the plugin dialog.

use std::process::Command;

const PICK_DIRECTORY: &str = r#"
import dbus, sys
from urllib.parse import unquote, urlparse
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
proxy = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
chooser = dbus.Interface(proxy, "org.freedesktop.portal.FileChooser")
choice = dbus.Struct((
    dbus.String("ordnance"),
    dbus.String(" "),
    dbus.Array([], signature="(ss)"),
    dbus.String(""),
), signature="(ssa(ss)s)")
token = "ordnancefolder%d" % __import__("os").getpid()
opts = dbus.Dictionary({
    "handle_token": dbus.String(token),
    "directory": dbus.Boolean(True),
    "modal": dbus.Boolean(True),
    "choices": dbus.Array([choice], signature="(ssa(ss)s)"),
}, signature="sv")
handle = chooser.OpenFile("", "Choose folder", opts)
loop = GLib.MainLoop()
picked = []

def on_response(response, results):
    if int(response) == 0:
        uris = results.get("uris", [])
        if uris:
            picked.append(unquote(urlparse(str(uris[0])).path))
    loop.quit()

bus.add_signal_receiver(
    on_response,
    signal_name="Response",
    dbus_interface="org.freedesktop.portal.Request",
    path=str(handle),
)
loop.run()
if picked:
    sys.stdout.write(picked[0])
"#;

/// `None` when the user cancels. The path field is the KDE file dialog's.
#[tauri::command]
pub fn pick_directory() -> Result<Option<String>, String> {
    let output = Command::new("python3")
        .arg("-c")
        .arg(PICK_DIRECTORY)
        .output()
        .map_err(|err| format!("folder dialog failed to start: {err}"))?;
    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        return Err(format!("folder dialog failed: {err}"));
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        Ok(None)
    } else {
        Ok(Some(path))
    }
}
