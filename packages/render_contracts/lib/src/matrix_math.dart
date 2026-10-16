import 'dart:math' as math;
import 'dart:typed_data';

Float32List multiplyMatrix4(Float32List left, Float32List right) {
  final result = Float32List(16);
  for (var column = 0; column < 4; column++) {
    for (var row = 0; row < 4; row++) {
      var sum = 0.0;
      for (var index = 0; index < 4; index++) {
        sum += left[index * 4 + row] * right[column * 4 + index];
      }
      result[column * 4 + row] = sum;
    }
  }
  return result;
}

Float32List transformPoint3(Float32List matrix, Float32List point) =>
    Float32List.fromList([
      for (var row = 0; row < 3; row++)
        matrix[row] * point[0] +
            matrix[4 + row] * point[1] +
            matrix[8 + row] * point[2] +
            matrix[12 + row],
    ]);

/// Rotation about Z, then X, then Y. Input angles are degrees, output XYZW.
Float32List eulerZxyDegreesToQuaternion(Float32List euler) {
  final hx = euler[0] * math.pi / 360,
      hy = euler[1] * math.pi / 360,
      hz = euler[2] * math.pi / 360;
  final sx = math.sin(hx),
      cx = math.cos(hx),
      sy = math.sin(hy),
      cy = math.cos(hy),
      sz = math.sin(hz),
      cz = math.cos(hz);
  return Float32List.fromList([
    sx * cy * cz + cx * sy * sz,
    cx * sy * cz - sx * cy * sz,
    cx * cy * sz - sx * sy * cz,
    cx * cy * cz + sx * sy * sz,
  ]);
}

Float32List trsMatrix4({
  required Float32List translation,
  required Float32List quaternion,
  required Float32List scale,
}) {
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
    ...translation,
    1,
  ]);
}

/// Inverse of an orthonormal rotation and translation matrix with unit scale.
Float32List inverseRigidMatrix4(Float32List matrix) {
  final result = Float32List(16);
  for (var row = 0; row < 3; row++) {
    for (var column = 0; column < 3; column++) {
      result[column * 4 + row] = matrix[row * 4 + column];
    }
    result[12 + row] =
        -(result[row] * matrix[12] +
            result[4 + row] * matrix[13] +
            result[8 + row] * matrix[14]);
  }
  result[15] = 1;
  return result;
}

/// Right-handed view projection; depth range is minus one to one.
Float32List perspectiveMatrix4({
  required double fovYDegrees,
  required double aspectRatio,
  required double near,
  required double far,
}) {
  if (!fovYDegrees.isFinite ||
      fovYDegrees <= 0 ||
      fovYDegrees >= 180 ||
      !aspectRatio.isFinite ||
      aspectRatio <= 0 ||
      !near.isFinite ||
      !far.isFinite ||
      near <= 0 ||
      far <= near) {
    throw ArgumentError('perspective_projection_parameters');
  }
  final focal = 1 / math.tan(fovYDegrees * math.pi / 360);
  final result = Float32List(16);
  result[0] = focal / aspectRatio;
  result[5] = focal;
  result[10] = -(far + near) / (far - near);
  result[11] = -1;
  result[14] = -(2 * far * near) / (far - near);
  return result;
}

Float32List remapClipDepthZeroToOne(Float32List matrix) {
  final result = Float32List.fromList(matrix);
  for (var column = 0; column < 4; column++) {
    final index = column * 4;
    result[index + 2] = (matrix[index + 2] + matrix[index + 3]) * .5;
  }
  return result;
}
