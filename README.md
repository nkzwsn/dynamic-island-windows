# Mini Island for Windows

A small, unobtrusive pill at the top center of your Windows 10/11 screen that shows your notifications
and what's playing, instead of the toasts in the bottom-right corner.

## Features

- **Notifications** pop up from the top center, colored with the app's icon color, with the sender's
  photo when the app includes one (Discord, WhatsApp, ...). Hover to read the full message, click to
  open the app (the notification is then cleared), swipe right to dismiss.
- **Notification list**: move the mouse to the thin line at the top center of the screen. Delete one by
  one (x or swipe right) or clear all.
- **WeChat** (which doesn't use Windows notifications) is detected from its flashing taskbar button.
- **Now Playing** for Spotify, YouTube Music / browsers, Apple Music and any app that shows in the
  Windows media flyout: cover, title, play/pause/next, the **player's own volume** (scroll on the card;
  your other apps and Windows' volume stay as they are, and for a browser it's the whole browser), and a
  wavy progress bar in the album's colors. **Click or drag the wave to jump** to another part of the song.
  Long titles and artist names scroll, and the card crossfades smoothly when the song changes.
  When several apps play at once, the one you can actually hear is shown: muted autoplay videos
  (Facebook, Instagram, ...) don't take over your music. For YouTube videos, the song and artist are
  read from the video title.
- **Mini island** while music plays: scrolling title and artist with a small progress wave, or the
  current **synced lyrics** (from [LRCLIB](https://lrclib.net)) with a karaoke sweep. Japanese lyrics
  get **furigana** and **romaji** (needs Japanese added in Windows: Settings > Time & language >
  Language & region > Add a language). Songs that only have plain lyrics show them line by line at an
  estimated pace. Lyrics you've already played are kept on your PC, so they load instantly next time.
- **Full lyrics page**: swipe to the third page of the list to see all the lyrics scrolling along with
  the song. Click a line to jump to it. Pin it to keep the island open, and turn furigana / romaji on or
  off for Japanese lyrics.
- **Album color glow**: a faint, still glow in the album's color around the island while music plays.
- **Volume & brightness**: a small level pill when you change them with the keyboard or taskbar.
- **Charging**: a short animation when you plug in a laptop, and a warning at 20% and 10% battery.
- **Bluetooth headset connected**: the device name and its battery (when the headset reports it).
- **Microphone / camera in use**: an orange (mic) or green (camera) dot next to the thin line. Hover
  it to see which app is using it.
- **Timer & stopwatch** (right-click menu). The time shows in the island, or in a small bubble next to
  it while music plays. Pause or stop it from the notification list.
- **Updates**: a new version shows up once as a pop-up, then stays in the notification list with a short
  list of what changed. Click it to install: the island downloads the new version, keeps your settings
  and saved lyrics, and restarts itself.
- **English or Indonesian** interface, and a choice of monitor if you have more than one.
- Stays on top of other windows, but steps aside for fullscreen games and videos.
- Light: well under 1% of your CPU when nothing is playing, about 2-3% while music plays (measured on a
  6-core PC with a 180 Hz screen).

## Install

1. Download this repository (green **Code** button > **Download ZIP**) and extract it.
2. Double-click **`Install.cmd`**. No admin rights needed.
   - If Windows SmartScreen warns about the file, choose *More info* > *Run anyway*.
3. When asked, **allow notification access**. If you missed the prompt: Settings > Privacy & security >
   Notifications > allow apps to access notifications.

The app is installed to `%LOCALAPPDATA%\MiniIsland` and starts automatically when you log in.

**Updating**: click the update in the notification list, or download the new ZIP and run `Install.cmd`
again. Your settings are kept either way. Installing over the
older *Dynamic Island* version also moves its settings and saved lyrics over and removes the old copy.

## Uninstall

Double-click **`Uninstall.cmd`** (in the downloaded folder or in `%LOCALAPPDATA%\MiniIsland`).

## Settings

**Right-click** the island, or the thin line at the top center when the island is hidden. The menu has:

- Lyrics on/off, furigana and romaji on/off, and lyric timing for all songs (if lyrics are early or late for your
  speakers/headset)
- Music volume: the player app only (default), or turn it off to have the music card change Windows' volume
- Timer (1-60 minutes) and stopwatch
- Show: volume & brightness changes, charging & low battery, microphone / camera dots, Bluetooth
  headset, album color glow
- Monitor, language, check for updates, restart, quit

**Lyric timing for one song**: scroll on the lyrics button of the music card. It is remembered for
that song.

## Privacy

- Notifications are read only on your PC and never leave it.
- When lyrics are on, the **title and artist** of what's playing are sent to lrclib.net to find the
  lyrics (only the first time a song is played; for videos in a browser, only when the title looks like
  a song). Turn lyrics off to stop this.
- To show the app you can actually hear, the island reads how loud each app currently is (the same
  levels as Windows' volume mixer). Nothing is recorded or sent anywhere.
- Once a day the app reads the `VERSION` file and the list of version changes of this repository on
  GitHub to check for updates. To turn this off, set `"CheckUpdates": false` in
  `%LOCALAPPDATA%\MiniIsland\settings.json`. An update is only downloaded (from this repository) when you
  click it; the previous version is kept as `island.ps1.bak`.
- The microphone / camera dots only read Windows' own privacy records; the app never uses them.
- Errors are logged to `island.log` in the install folder.

## Requirements

Windows 10 or 11 with Windows PowerShell 5.1 (built in). No other software is needed.

## License

[MIT](LICENSE): free to use, modify and share.
