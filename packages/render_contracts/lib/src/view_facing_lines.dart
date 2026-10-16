import 'dart:math' as math;
import 'dart:typed_data';

import 'render_graph.dart';

final class ViewFacingLineSpec {
  ViewFacingLineSpec({
    required this.from,
    required this.to,
    required this.widthNear,
    required this.widthFar,
    required this.rgbaNear,
    required this.rgbaFar,
    Float32List? uvRect,
    this.uvCorners,
  }) : uvRect = uvRect ?? Float32List.fromList([0, 1, 1, 0]);

  final Float32List from, to, rgbaNear, rgbaFar, uvRect;

  /// Explicit UV pairs for near-left, near-right, far-left, far-right.
  final Float32List? uvCorners;
  final double widthNear, widthFar;
}

/// Camera-facing segments with a separate width and color at each endpoint.
GeometryBuffer buildViewFacingLineStrips(
  Iterable<ViewFacingLineSpec> specs, {
  required Float32List cameraPosition,
  required Float32List clipFromWorld,
}) {
  if (cameraPosition.length != 3 || clipFromWorld.length != 16) {
    throw ArgumentError('view_facing_line_camera');
  }
  final lines = specs.toList(growable: false);
  if (lines.length > 16384) {
    throw ArgumentError('view_facing_line_uint16_capacity');
  }
  final vertices = Float32List(lines.length * 4 * 10);
  final indices = Uint16List(lines.length * 6);
  for (final (lineIndex, line) in lines.indexed) {
    if (line.from.length != 3 ||
        line.to.length != 3 ||
        line.rgbaNear.length != 4 ||
        line.rgbaFar.length != 4 ||
        line.uvRect.length != 4 ||
        (line.uvCorners != null && line.uvCorners!.length != 8) ||
        !line.widthNear.isFinite ||
        !line.widthFar.isFinite ||
        line.widthNear < 0 ||
        line.widthFar < 0) {
      throw ArgumentError('view_facing_line_spec');
    }
    final tx = line.to[0] - line.from[0];
    final ty = line.to[1] - line.from[1];
    final tz = line.to[2] - line.from[2];
    for (var vertex = 0; vertex < 4; vertex++) {
      final near = vertex < 2;
      final point = near ? line.from : line.to;
      final dx = cameraPosition[0] - point[0];
      final dy = cameraPosition[1] - point[1];
      final dz = cameraPosition[2] - point[2];
      final sx = ty * dz - tz * dy;
      final sy = tz * dx - tx * dz;
      final sz = tx * dy - ty * dx;
      final length = math.sqrt(sx * sx + sy * sy + sz * sz);
      if (!length.isFinite || length <= 1e-12) {
        throw ArgumentError('view_facing_line_degenerate');
      }
      final offset =
          (vertex.isEven ? 1 : -1) *
          (near ? line.widthNear : line.widthFar) /
          (2 * length);
      final x = point[0] + sx * offset;
      final y = point[1] + sy * offset;
      final z = point[2] + sz * offset;
      final base = (lineIndex * 4 + vertex) * 10;
      for (var row = 0; row < 4; row++) {
        vertices[base + row] =
            clipFromWorld[row] * x +
            clipFromWorld[row + 4] * y +
            clipFromWorld[row + 8] * z +
            clipFromWorld[row + 12];
      }
      vertices[base + 4] =
          line.uvCorners?[vertex * 2] ?? line.uvRect[vertex.isEven ? 0 : 2];
      vertices[base + 5] =
          line.uvCorners?[vertex * 2 + 1] ?? line.uvRect[near ? 1 : 3];
      vertices.setRange(
        base + 6,
        base + 10,
        near ? line.rgbaNear : line.rgbaFar,
      );
    }
    final base = lineIndex * 4;
    indices.setRange(lineIndex * 6, lineIndex * 6 + 6, [
      base,
      base + 1,
      base + 2,
      base + 2,
      base + 1,
      base + 3,
    ]);
  }
  return GeometryBuffer(vertices, indices, layout: VertexLayout.sprite);
}
