// SPDX-License-Identifier: AGPL-3.0-or-later

//! Raw SDL3 C bindings (audio + HIDAPI subsets) behind one import. The
//! `sdl` build dependency statically compiles SDL3 and ships its headers.

/// SDL3 C declarations used by the audio and HID backends.
pub const c = @cImport({
    @cInclude("SDL3/SDL_stdinc.h");
    @cInclude("SDL3/SDL_error.h");
    @cInclude("SDL3/SDL_hints.h");
    @cInclude("SDL3/SDL_init.h");
    @cInclude("SDL3/SDL_audio.h");
    @cInclude("SDL3/SDL_hidapi.h");
});
