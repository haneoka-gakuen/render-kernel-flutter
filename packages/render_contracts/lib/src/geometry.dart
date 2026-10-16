import 'dart:typed_data';

import 'render_graph.dart';

/// Source mesh is the actual decoded Sprite geometry/UV, in local mesh units.
final class GeometryShape {
  GeometryShape({
    required Float32List positions,
    required Float32List uv,
    required Uint16List indices,
  }) : positions = Float32List.fromList(positions).asUnmodifiableView(),
       uv = Float32List.fromList(uv).asUnmodifiableView(),
       indices = Uint16List.fromList(indices).asUnmodifiableView() {
    if (positions.length % 3 != 0 ||
        uv.length * 3 != positions.length * 2 ||
        positions.any((v) => !v.isFinite) ||
        uv.any((v) => !v.isFinite)) {
      throw ArgumentError('native_invalid_sprite_geometry');
    }
  }
  final Float32List positions, uv;
  final Uint16List indices;
}

/// Camera/model matrices are column-major and provided by the renderer-neutral
/// scene producer. Perspective is applied once; XY screen-root sprites
/// and world-stage geometry receive their respective authored transforms.
/// Baseline shader tint is in decoded image display space. HDR/linear materials
/// require a separate shader recipe; this boundary does not silently linearize.
GeometryBuffer projectGeometry(
  GeometryShape sprite,
  Float32List clipFromLocal,
  Float32List tintRgba,
) {
  if (clipFromLocal.length != 16 ||
      tintRgba.length != 4 ||
      clipFromLocal.any((v) => !v.isFinite) ||
      tintRgba.any((v) => !v.isFinite)) {
    throw ArgumentError('native_invalid_projection');
  }
  final count = sprite.positions.length ~/ 3;
  final output = Float32List(count * 10);
  for (var vertex = 0; vertex < count; vertex++) {
    final x = sprite.positions[vertex * 3];
    final y = sprite.positions[vertex * 3 + 1];
    final z = sprite.positions[vertex * 3 + 2];
    final target = vertex * 10;
    for (var row = 0; row < 4; row++) {
      output[target + row] =
          clipFromLocal[row] * x +
          clipFromLocal[4 + row] * y +
          clipFromLocal[8 + row] * z +
          clipFromLocal[12 + row];
    }
    output[target + 4] = sprite.uv[vertex * 2];
    output[target + 5] = sprite.uv[vertex * 2 + 1];
    for (var channel = 0; channel < 4; channel++) {
      output[target + 6 + channel] = tintRgba[channel];
    }
  }
  return GeometryBuffer(output, sprite.indices);
}

/// Actual prefab TRS: XYZ and quaternion XYZW are retained, including non-planar Z.
final class LocalTransform {
  LocalTransform({
    required Float32List position,
    required Float32List quaternion,
    required Float32List scale,
  }) : position = Float32List.fromList(position).asUnmodifiableView(),
       quaternion = Float32List.fromList(quaternion).asUnmodifiableView(),
       scale = Float32List.fromList(scale).asUnmodifiableView() {
    if (position.length != 3 ||
        quaternion.length != 4 ||
        scale.length != 3 ||
        [...position, ...quaternion, ...scale].any((v) => !v.isFinite)) {
      throw ArgumentError('native_transform_shape');
    }
    final length2 = quaternion.fold<double>(0, (sum, v) => sum + v * v);
    if ((length2 - 1).abs() > 0.001) {
      throw ArgumentError('native_transform_nonunit_quaternion');
    }
  }
  final Float32List position, quaternion, scale;

  Float32List matrix() {
    final x = quaternion[0],
        y = quaternion[1],
        z = quaternion[2],
        w = quaternion[3];
    return Float32List.fromList([
      (1 - 2 * (y * y + z * z)) * scale[0],
      2 * (x * y + z * w) * scale[0],
      2 * (x * z - y * w) * scale[0],
      0,
      2 * (x * y - z * w) * scale[1],
      (1 - 2 * (x * x + z * z)) * scale[1],
      2 * (y * z + x * w) * scale[1],
      0,
      2 * (x * z + y * w) * scale[2],
      2 * (y * z - x * w) * scale[2],
      (1 - 2 * (x * x + y * y)) * scale[2],
      0,
      position[0],
      position[1],
      position[2],
      1,
    ]);
  }
}

Float32List composeClipFromLocal(
  Float32List clipFromWorld,
  LocalTransform local,
) {
  if (clipFromWorld.length != 16 || clipFromWorld.any((v) => !v.isFinite)) {
    throw ArgumentError('native_camera_matrix');
  }
  final model = local.matrix(), result = Float32List(16);
  for (var column = 0; column < 4; column++) {
    for (var row = 0; row < 4; row++) {
      var value = 0.0;
      for (var index = 0; index < 4; index++) {
        value += clipFromWorld[index * 4 + row] * model[column * 4 + index];
      }
      result[column * 4 + row] = value;
    }
  }
  return result;
}
