# Manual candidate checks

Test the app extracted from the candidate's ZIP. Its generated
`manual-smoke-template.json` already contains the archive checksum. Copy the
template outside the source tree, fill in your name, time with timezone
(for example `2026-10-08T23:30:00+08:00`), macOS version, architecture,
and results. Use `passed` only after observing the behavior.

| Check | Expected behavior |
| --- | --- |
| `install_and_launch` | Extract the ZIP, install Rack.app in Applications, and open it. The rack and menu bar controls appear without a crash. |
| `system_audio_permission` | Grant audio capture access if prompted; the engine reaches Running and processes audio. Note an existing permission grant if no new prompt appears. |
| `listening_and_bypass` | Play audio, change EQ, and toggle bypass. The audible change follows the controls; bypass restores the original processing state without stuck silence. |
| `app_volume_and_mute` | Play two addressable apps. Change one app's level and mute it; the other app continues playing at its own level. |
| `output_device_switch` | Switch between available outputs and disconnect/reconnect an external output. Rack follows the device change and recovers audio. Record the tested devices. |
| `presets_and_restore` | Save/recall a preset, change settings, quit, and relaunch. Presets and intended session settings survive. |
| `menu_bar_and_quit` | Close the window; processing continues. Reopen it from the menu bar or shortcut. Quit Rack; normal system playback continues. Check launch at login if enabled for testing. |
| `microphone_monitoring` | With headphones, choose an input, allow microphone access, enable monitoring, and test level/mute/Guard. Disable monitoring afterward. |

Every required check must pass. Microphone monitoring can use `skipped` with
a concrete hardware reason; the other checks cannot be skipped. Record device
names and any limitations in `notes`. A manual check on one architecture does
not imply a check on the other, or on the oldest supported macOS version.

Import the completed record with:

```sh
python3 Scripts/release.py record-smoke CANDIDATE-DIRECTORY --file completed-smoke.json
```

A changed archive requires a new candidate and new manual checks. Never
replace the tested ZIP with a freshly rebuilt copy while publishing.
