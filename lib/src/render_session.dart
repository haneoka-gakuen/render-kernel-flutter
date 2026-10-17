import 'dart:ui' as ui;
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'gpu_frame_renderer.dart';
import 'texture_loader.dart';

import 'package:render_contracts/render_contracts.dart';

/// Platform host plugs this into its existing page/RawImage. No theme or layout.
/// The source producer owns chart/story simulation and the actual audio timestamp.
class RenderSession {
  RenderSession({
    required this.renderer,
    required ResourceFetch fetch,
    bool reuseDecodedImages = true,
    bool retainDecodedImageMipmaps = true,
  }) : _loader = TextureLoader(
         fetch: fetch,
         renderer: renderer,
         reuseDecodedImages: reuseDecodedImages,
         retainDecodedImageMipmaps: retainDecodedImageMipmaps,
       );
  final GpuFrameRenderer renderer;
  final TextureLoader _loader;
  final ValueNotifier<ui.Image?> image = ValueNotifier(null);
  int _generation = 0;
  bool _disposed = false;
  bool _ready = false;
  bool _presenting = false;
  Future<void> _active = Future.value();
  final _installedTextures = <String, Uri>{};
  final _installedDataTextures = <String, TextureData>{};

  Future<void> open({
    required ByteData handwrittenShaderBundle,
    required RenderScene scene,
    required Map<String, Uri> textures,
    required RenderFrame initialFrame,
    Map<String, TextureData> dataTextures = const {},
  }) {
    if (_disposed) throw StateError('gpu_session_disposed');
    for (final key in dataTextures.keys) {
      if (textures.containsKey(key)) {
        throw StateError('gpu_numeric_image_key_collision:$key');
      }
    }
    final generation = ++_generation;
    _ready = false;
    _loader.cancel();
    final install = _active.then((_) async {
      if (generation != _generation || _disposed) return;
      renderer.clearResources();
      _installedTextures.clear();
      _installedDataTextures.clear();
      await renderer.installShaders(handwrittenShaderBundle);
      if (generation != _generation || _disposed) return;
      await _loader.install(textures);
      if (generation != _generation || _disposed) return;
      _installedTextures.addAll(textures);
      for (final entry in dataTextures.entries) {
        final value = entry.value;
        await renderer.installTextureData(
          entry.key,
          value.width,
          value.height,
          value.rgba,
          alpha: value.alpha,
          encoding: value.encoding,
          format: value.format,
        );
        if (generation != _generation || _disposed) return;
        _installedDataTextures[entry.key] = value;
      }
      renderer.installScene(scene);
      _ready = true;
    });
    _active = install.catchError((Object _) {});
    return install.then<void>((_) async {
      if (generation != _generation || _disposed || !_ready) return;
      await present(initialFrame);
    });
  }

  Future<void> present(
    RenderFrame frame, {
    RenderScene? resources,
    bool Function()? stillCurrent,
  }) {
    if (_disposed || !_ready) {
      return Future.error(StateError('gpu_session_not_ready'));
    }
    if (_presenting) {
      return Future.error(StateError('gpu_session_frame_busy'));
    }
    _presenting = true;
    final generation = _generation;
    final operation = _active
        .then((_) async {
          if (_disposed || generation != _generation) return;
          if (resources != null) {
            if (kProfileMode) {
              developer.Timeline.timeSync(
                'render.upload',
                () => renderer.updateSceneResources(resources),
              );
            } else {
              renderer.updateSceneResources(resources);
            }
          }
          final submitTrace = kProfileMode
              ? (developer.TimelineTask()..start('render.submit'))
              : null;
          final ui.Image next;
          try {
            next = await renderer.render(frame);
          } finally {
            submitTrace?.finish();
          }
          if (_disposed ||
              generation != _generation ||
              (stillCurrent != null && !stillCurrent())) {
            next.dispose();
            return;
          }
          final previous = image.value;
          image.value = next;
          if (previous != null) {
            // The old RawImage may still belong to the current Flutter frame.
            // Retire its lease at a compositor frame boundary, not on assignment.
            SchedulerBinding.instance.endOfFrame.then(
              (_) => previous.dispose(),
            );
          }
        })
        .whenComplete(() {
          _presenting = false;
        });
    // Keep a failed GPU submission visible to caller without poisoning next open.
    _active = operation.catchError((Object _) {});
    return operation;
  }

  /// A normal story may introduce a new source glyph atlas or image after a
  /// command. Install only those resources, after the prior GPU presentation.
  Future<void> ensureTextures(Map<String, Uri> textures) {
    if (_disposed || !_ready) throw StateError('gpu_session_not_ready');
    final generation = _generation;
    final requested = Map<String, Uri>.of(textures);
    final operation = _active.then((_) async {
      if (_disposed || generation != _generation) return;
      final missing = <String, Uri>{};
      for (final entry in requested.entries) {
        if (_installedDataTextures.containsKey(entry.key)) {
          throw StateError('gpu_numeric_image_key_collision:${entry.key}');
        }
        final existing = _installedTextures[entry.key];
        if (existing != null && existing != entry.value) {
          throw StateError('gpu_texture_source_key_changed:${entry.key}');
        }
        if (existing == null) missing[entry.key] = entry.value;
      }
      if (missing.isEmpty) return;
      await _loader.install(missing);
      if (_disposed || generation != _generation) return;
      _installedTextures.addAll(missing);
    });
    _active = operation.catchError((Object _) {});
    return operation;
  }

  /// Source-owned immutable numeric texels may change within a scene epoch.
  /// Providers retain each TextureData instance while its content is unchanged.
  Future<void> ensureDataTextures(Map<String, TextureData> textures) {
    if (_disposed || !_ready) throw StateError('gpu_session_not_ready');
    final generation = _generation;
    final requested = Map<String, TextureData>.of(textures);
    final operation = _active.then((_) async {
      for (final entry in requested.entries) {
        if (_disposed || generation != _generation) return;
        if (_installedTextures.containsKey(entry.key)) {
          throw StateError('gpu_numeric_image_key_collision:${entry.key}');
        }
        final value = entry.value;
        if (identical(_installedDataTextures[entry.key], value)) continue;
        await renderer.installTextureData(
          entry.key,
          value.width,
          value.height,
          value.rgba,
          alpha: value.alpha,
          encoding: value.encoding,
          format: value.format,
        );
        if (_disposed || generation != _generation) return;
        _installedDataTextures[entry.key] = value;
      }
    });
    _active = operation.catchError((Object _) {});
    return operation;
  }

  /// Producers can reinstall these keys with ensureTextures/ensureDataTextures.
  Future<void> releaseTextures(Iterable<String> textures) {
    if (_disposed || !_ready) throw StateError('gpu_session_not_ready');
    final generation = _generation;
    final requested = textures.toSet();
    final operation = _active.then((_) {
      if (_disposed || generation != _generation) return;
      renderer.releaseTextures(requested);
      for (final key in requested) {
        _installedTextures.remove(key);
        _installedDataTextures.remove(key);
      }
    });
    _active = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = false;
    _generation++;
    _loader.cancel();
    await _active;
    image.value?.dispose();
    image.dispose();
    renderer.dispose();
  }
}
