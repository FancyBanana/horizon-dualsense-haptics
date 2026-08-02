// SPDX-License-Identifier: AGPL-3.0-or-later

//! Raw SDL3 C bindings, kept behind one import so the rest of the app only
//! sees the small `sdl` namespace. The `sdl` build dependency (castholm/SDL)
//! statically compiles SDL3 and ships its headers; the build script exposes
//! its `include/` directory to this module, so `@cImport` resolves the
//! SDL3/SDL_*.h headers without any system SDL. Only the audio subset is
//! imported, which keeps `@cImport` and the linked library small.

pub const c = @cImport({
    @cInclude("SDL3/SDL_stdinc.h");
    @cInclude("SDL3/SDL_error.h");
    @cInclude("SDL3/SDL_hints.h");
    @cInclude("SDL3/SDL_init.h");
    @cInclude("SDL3/SDL_audio.h");
});
