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
    for (final entry in textures.entries) {
      if (generation != _generation) return;
      final numeric = await textureDataFetch?.call(entry.value);
      if (generation != _generation) return;
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
        continue;
      }
      final bytes = await fetch(entry.value);
      if (generation != _generation) return;
      final codec = await ui.instantiateImageCodec(bytes);
      late final int width, height;
      late final ByteData? pixels;
      try {
        final frame = await codec.getNextFrame();
        try {
          if (reuseDecodedImages && retainDecodedImageMipmaps) {
            if (generation != _generation) return;
            renderer.installDecodedImage(entry.key, frame.image);
            continue;
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
  }

  void cancel() {
    _generation++;
  }
}
