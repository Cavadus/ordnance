// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // Prefer the desktop portal's native file dialog (KDE's has a typeable
    // path) over GTK's breadcrumb-only chooser. Must be set before GTK
    // initializes; this used to live in the old launcher script.
    #[cfg(target_os = "linux")]
    std::env::set_var("GTK_USE_PORTAL", "1");
    ordnance_lib::run()
}
