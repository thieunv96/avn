---
paths:
  - "**/*{stream,pipeline,decode,encode,inference,infer,track,gst,gstreamer,camera,audio,frame,buffer,rtsp,reconnect}*.{py,cpp,cc,c,h,hpp,go,rs}"
---

# Realtime and performance-critical code

> The `paths` globs above are heuristic — realtime hot paths can only be matched by file name, not
> content. Tune them to each project's actual layout.

Hot paths include: video decode, audio processing, inference loops, tracking, streaming/GStreamer
pipelines, camera reconnect logic, audio/video sync, frame buffering, and GPU/CPU scheduling.

- **Do not "optimize" or refactor these areas without measurement.**
- For any performance change, follow: (1) identify the metric, (2) measure current behavior, (3) make the smallest change, (4) measure again, (5) report before/after numbers.

Useful metrics: latency, FPS, CPU/GPU usage, memory, dropped frames, queue size, reconnect time,
throughput.

## Testing this code

Strict unit-first TDD often does not fit here. Prefer benchmarks, recorded fixtures, and
integration tests over the real pipeline.
