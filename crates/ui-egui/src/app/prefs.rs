use super::{LightcraftApp, SCREEN_PROFILE, theme};

impl LightcraftApp {
    /// The system's appearance: the host's answer first, then egui's (none: unknown).
    pub fn system_theme(&self, ctx: &egui::Context) -> Option<egui::Theme> {
        self.services.system_theme.as_ref().and_then(|read| read(ctx)).or_else(|| ctx.system_theme())
    }

    /// Restyle `ctx` with the theme the settings select (Appearance Mode, the dark and light
    /// themes, the system's appearance in Auto), drawn from the current suite palette when there
    /// is one and from the built-in theme otherwise.
    pub fn apply_theme(&mut self, ctx: &egui::Context) {
        let kind = self.ui.settings.theme(self.system_theme(ctx));
        theme::apply_kind_with_palette(ctx, kind, self.palette.as_ref());
    }

    /// Restyle `ctx` when the theme the settings select (Appearance Mode, the dark and light
    /// themes, the system's appearance in Auto) is not the one it shows. A no-op otherwise.
    pub fn sync_theme(&mut self, ctx: &egui::Context) {
        let wanted = self.ui.settings.theme(self.system_theme(ctx));
        if theme::current(ctx) != Some(wanted) {
            theme::apply_kind_with_palette(ctx, wanted, self.palette.as_ref());
        }
    }

    /// Pick up a palette file changed since the last poll and restyle with it. The file is read on
    /// the frame thread, at most every 400 ms, and only while the window is visible: a hidden
    /// window must not wake every 400 ms. The web build has no file to watch: it keeps the
    /// built-in theme.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn poll_palette(&mut self, ctx: &egui::Context) {
        if !viewport_visible(ctx) {
            return;
        }
        let loaded = self.palette_watcher.as_mut().and_then(|watcher| watcher.poll(ctx));
        let Some(loaded) = loaded else { return };
        self.palette = Some(loaded.palette);
        self.apply_theme(ctx);
    }

    /// Back from an external editor: pick up the files it saved. Reads `i.focused`, which
    /// `run_logic` does not refresh, so it belongs to the UI phase.
    pub(super) fn check_external_editor(&mut self, ctx: &egui::Context) {
        let focused = ctx.input(|i| i.focused);
        if focused && !self.ui.was_focused && !self.ui.external_edits.is_empty() {
            let ids = self.ui.external_edits.clone();
            if let Ok(r) = self.session.execute("photo.reload", &serde_json::json!({"ids": ids}))
                && r["reloaded"].as_array().is_some_and(|a| !a.is_empty())
            {
                self.toast(ctx, crate::i18n::tr("Updated the edits saved in the external editor"));
            }
        }
        self.ui.was_focused = focused;
    }

    /// Apply settings that act outside the UI state: GPU rendering and window full screen.
    pub(super) fn apply_settings(&mut self, ctx: &egui::Context) {
        if self.gpu_applied != Some(self.ui.settings.gpu) {
            self.gpu_applied = Some(self.ui.settings.gpu);
            let _ = self.session.execute("app.gpu", &serde_json::json!({"enabled": self.ui.settings.gpu, "wait": false}));
            // GPU device + kernels off the UI thread, once the window is up and only when GPU
            // rendering is on: a broken driver must not keep the window from appearing (issue #136)
            if self.ui.settings.gpu {
                lightcraft_engine::gpu::warm_up();
            }
        }
        let mb = self.ui.settings.memory_mb;
        // automatic at startup: leave the engine's default alone
        if self.memory_applied != Some(mb) && (mb > 0 || self.memory_applied.is_some()) {
            let mb = if mb == 0 { (lightcraft_engine::memory::default_budget() >> 20) as u32 } else { mb };
            let _ = self.session.execute("app.memoryBudget", &serde_json::json!({"mb": mb}));
        }
        self.memory_applied = Some(mb);
        // the monitor profile (Settings ▸ Display): previews follow it from the next frame
        if self.display_applied.as_ref() != Some(&self.ui.settings.display_profile) {
            let path = self.ui.settings.display_profile.clone();
            match lightcraft_engine::display::Display::load_opt(&path) {
                Ok(d) => {
                    self.renderer.set_display(d);
                    self.display_error = None;
                }
                Err(msg) => {
                    // a profile that can't be used: previews are sRGB, the setting is kept
                    self.renderer.set_display(None);
                    log::warn!("display profile: {msg}");
                    self.toast_error(ctx, format!("{}: {msg}", crate::i18n::tr("Display profile not used")));
                    self.display_error = Some(msg);
                }
            }
            self.display_applied = Some(path);
            // none chosen again: the screen's profile is read afresh
            self.screen_profile = None;
            self.screen_profile_read = None;
        }
        if self.ui.settings.display_profile.is_empty() {
            self.follow_screen_profile(ctx);
        }
        if let Some(fs) = ctx.input(|i| i.viewport().fullscreen) {
            self.window_is_fullscreen = fs;
        }
        if let Some(on) = self.ui.window_fullscreen.take() {
            ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(on));
            self.window_is_fullscreen = on;
        }
    }

    /// While no display profile is chosen, show previews through the profile of the screen the
    /// window is on (`services.screen_profile`), read about once a second so moving the window to
    /// another screen is followed. Without the service (or a profile) the display is sRGB.
    fn follow_screen_profile(&mut self, _ctx: &egui::Context) {
        let now = self.tick_now();
        if self.services.screen_profile.is_none() || self.screen_profile_read.is_some_and(|t| (0.0..1.0).contains(&(now - t))) {
            return;
        }
        self.screen_profile_read = Some(now);
        self.apply_screen_profile();
    }

    /// Read the screen's profile now and show previews through it (sRGB without one).
    pub(crate) fn apply_screen_profile(&mut self) {
        let Some(read) = self.services.screen_profile.as_mut() else { return };
        let icc = read();
        if icc == self.screen_profile {
            return;
        }
        let display = icc.as_deref().and_then(|bytes| match lightcraft_engine::display::Display::from_bytes(SCREEN_PROFILE, bytes) {
            Ok(d) => Some(std::sync::Arc::new(d)),
            Err(msg) => {
                // a profile we can't use: previews stay sRGB, as before #787
                log::warn!("screen profile: {msg}");
                None
            }
        });
        self.renderer.set_display(display);
        self.screen_profile = icc;
    }
}

/// Whether the host reports the window as visible. A host that says nothing (headless,
/// `RawInput::default`) counts as visible, as the app's other hidden-window checks do.
#[cfg(not(target_arch = "wasm32"))]
fn viewport_visible(ctx: &egui::Context) -> bool {
    ctx.input(|input| input.viewport().visible().unwrap_or(true))
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;

    fn viewport(minimized: bool, occluded: bool) -> egui::RawInput {
        let info = egui::ViewportInfo { minimized: Some(minimized), occluded: Some(occluded), ..Default::default() };
        let mut viewports = egui::ViewportIdMap::default();
        viewports.insert(egui::ViewportId::ROOT, info);
        egui::RawInput { viewports, ..Default::default() }
    }

    /// A hidden window never reaches the palette watcher, so it does not wake every 400 ms; a host
    /// that reports no visibility at all is treated as visible.
    #[test]
    fn a_hidden_window_is_not_visible_to_the_palette_poll() {
        let ctx = egui::Context::default();
        let mut seen = Vec::new();
        let _ = ctx.run_pass(viewport(true, false), |ctx| seen.push(viewport_visible(ctx)));
        let _ = ctx.run_pass(viewport(false, true), |ctx| seen.push(viewport_visible(ctx)));
        let _ = ctx.run_pass(viewport(false, false), |ctx| seen.push(viewport_visible(ctx)));
        assert_eq!(seen, [false, false, true]);

        let unknown = egui::Context::default();
        let mut seen = None;
        let _ = unknown.run_pass(egui::RawInput::default(), |ctx| seen = Some(viewport_visible(ctx)));
        assert_eq!(seen, Some(true));
    }
}
