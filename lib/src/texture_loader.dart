import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:render_contracts/render_contracts.dart'
    show TextureAlpha, TextureData;

import 'gpu_frame_renderer.dart';

/// App supplies its existing release-pinned fetch/cache and network policy.
typedef ResourceFetch = Future<Uint8List> Function(Uri uri);
typedef TextureDataFetch = Future<TextureData?> Function(Uri uri);

final class TextureLoader {
  TextureLoader({
    required this.fetch,
    required this.renderer,
    this.textureDataFetch,
    this.reuseDecodedImages = true,
    this.retainDecodedImageMipmaps = true,
  });
  final bool reuseDecodedImages;

  /// Retain the decoder's mip pyramid when sharing its GPU image. Atlas
  /// producers can request one level while keeping premultiplied image pixels.
  final bool retainDecodedImageMipmaps;
  final ResourceFetch fetch;
  final TextureDataFetch? textureDataFetch;
  final GpuFrameRenderer renderer;
  int _generation = 0;

  /// Network and image decode stay outside render(); replacing source cancels install.
  Future<void> install(Map<String, Uri> textures) async {
    final generation = ++_generation;
    final entries = textures.entries.toList(growable: false);
    final pending = <int, Future<_TextureSource>>{};
    var next = 0;
    Future<void> probing = Future.value();

    Future<_TextureSource> prepare(Uri uri) {
      // A host's numeric-texture lookup may decompress an atlas. Keep those
      // callbacks serial while ordinary encoded downloads overlap.
      final probe = probing.then((_) async {
        if (generation != _generation) return null;
        return textureDataFetch?.call(uri);
      });
      probing = probe.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      return () async {
        try {
          final numeric = await probe;
          if (generation != _generation) return _TextureSource.cancelled;
          if (numeric != null) return _TextureSource(numeric: numeric);
          final bytes = await fetch(uri);
          return generation == _generation
              ? _TextureSource(bytes: bytes)
              : _TextureSource.cancelled;
        } catch (error, stack) {
          // Every launched download has an error handler immediately, even
          // when an earlier item fails or the install has been cancelled.
          return _TextureSource(error: error, stack: stack);
        }
      }();
    }

    void prefetch() {
      while (generation == _generation &&
          pending.length < 4 &&
          next < entries.length) {
        pending[next] = prepare(entries[next].value);
        next++;
      }
    }

    prefetch();
    try {
      for (var index = 0; index < entries.length; index++) {
        if (generation != _generation) return;
        await _consume(entries[index], pending.remove(index)!, generation);
        if (generation != _generation) return;
        prefetch();
      }
    } catch (_) {
      if (generation == _generation) _generation++;
      rethrow;
    } finally {
      pending.clear();
    }
  }

  Future<void> _consume(
    MapEntry<String, Uri> entry,
    Future<_TextureSource> pending,
    int generation,
  ) async {
    final source = await pending;
    if (generation != _generation) return;
    if (source.error case final error?) {
      Error.throwWithStackTrace(error, source.stack!);
    }
    final numeric = source.numeric;
    if (numeric != null) {
      await renderer.installTextureData(
        entry.key,
        numeric.width,
        numeric.height,
        numeric.rgba,
        alpha: numeric.alpha,
        encoding: numeric.encoding,
        format: numeric.format,
      );
      return;
    }
    final codec = await ui.instantiateImageCodec(source.bytes!);
    late final int width, height;
    late final ByteData? pixels;
    try {
      final frame = await codec.getNextFrame();
      try {
        if (reuseDecodedImages && retainDecodedImageMipmaps) {
          if (generation != _generation) return;
          renderer.installDecodedImage(entry.key, frame.image);
          return;
        }
        width = frame.image.width;
        height = frame.image.height;
        pixels = await frame.image.toByteData(
          format: reuseDecodedImages
              ? ui.ImageByteFormat.rawRgba
              : ui.ImageByteFormat.rawStraightRgba,
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
    if (generation != _generation) return;
    if (pixels == null) {
      throw StateError('gpu_texture_decode_failed:${entry.key}');
    }
    if (reuseDecodedImages) {
      await renderer.installTextureData(
        entry.key,
        width,
        height,
        pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
        alpha: TextureAlpha.premultiplied,
      );
    } else {
      renderer.installTexture(entry.key, width, height, pixels);
    }
  }

  void cancel() {
    _generation++;
  }
}

final class _TextureSource {
  const _TextureSource({this.numeric, this.bytes, this.error, this.stack});
  static const cancelled = _TextureSource();
  final TextureData? numeric;
  final Uint8List? bytes;
  final Object? error;
  final StackTrace? stack;
}
