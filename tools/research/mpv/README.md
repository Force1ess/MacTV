# Isolated IINA/mpv color probe

Build with `swift build -c release --package-path tools/research/mpv`.
Arguments: `<libmpv-dylib> <owned-local-video> <output-directory> <vo>`.
The probe uses the public mpv client ABI through an original dynamic wrapper.
No IINA settings, media, global audio routing or MacTV watch history are changed.
The selected engine stays in its original installation; no production dependency
is introduced. Playback is muted and bounded to 15 seconds. Renderer parameters,
actual playing time and renderer-generated RGB screenshots are recorded so that
decoding alone cannot be mistaken for correct Dolby Vision color conversion.

Client API: https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h
Output documentation: https://mpv.io/manual/stable/

`--inspect-audio <libmpv> <owned-local-video> <output-directory> null` is a
headless, muted demux/decoder comparison from time zero. It records track
selection and audio properties with a null audio sink; it does not verify HDMI
or physical audibility and does not produce screenshots. The ordinary color
probe keeps its original 60-second start and screenshot behavior.
An explicit `--audio-device=coreaudio/DEVICE_UID` in audio-inspection mode
compares the same decoder against that output instead of the null sink. It stays
muted at zero volume and does not change default audio devices.
