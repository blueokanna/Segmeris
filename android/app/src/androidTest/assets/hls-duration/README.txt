Synthetic fixture: 18 seconds, 160x90 H.264 at 10 fps plus AAC, three six-second fMP4 segments.
Generated with FFmpeg (run from this directory):
ffmpeg -y -v error -f lavfi -i testsrc=size=160x90:rate=10 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 18 -c:v libx264 -pix_fmt yuv420p -g 60 -c:a aac -hls_time 6 -hls_playlist_type vod -hls_segment_type fmp4 index.m3u8
Contains no downloaded or third-party media.
