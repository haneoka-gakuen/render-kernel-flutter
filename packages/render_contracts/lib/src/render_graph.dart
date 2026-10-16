import 'dart:typed_data';

enum TextureOrigin { topLeft, bottomLeft }

enum ColorEncoding { gammaSrgb, linear, sqrtLinear }

/// Explicit source transfer convention; UV origin is never inferred by backend.
final class TextureDescriptor {
  const TextureDescriptor({
    required this.width,
    required this.height,
    required this.alpha,
    this.origin = TextureOrigin.topLeft,
    this.encoding = ColorEncoding.gammaSrgb,
    this.format = TargetFormat.rgba8,
  });
  final int width, height;
  final TextureAlpha alpha;
  final TextureOrigin origin;
  final ColorEncoding encoding;
  final TargetFormat format;
}

/// Actual source numeric texels, kept straight and outside UIImage decoding.
final class TextureData {
  TextureData({
    required this.width,
    required this.height,
    required Uint8List rgba,
    this.alpha = TextureAlpha.straight,
    this.encoding = ColorEncoding.gammaSrgb,
    this.format = TargetFormat.rgba8,
  }) : rgba = Uint8List.fromList(rgba).asUnmodifiableView();
  final int width, height;
  final Uint8List rgba;
  final TextureAlpha alpha;
  final ColorEncoding encoding;
  final TargetFormat format;
}

enum TextureAlpha { straight, premultiplied, independent }

enum DrawBlend {
  opaque,
  premultipliedAlpha,
  additive,
  additivePreserveAlpha,
  multiply,
  sourceAlphaAdditive,
  coverageUnion,
  sourceAlpha,
}

enum DrawCull { none, back, front }

enum SamplerAddress { clampToEdge, repeat, mirror }

enum SamplerFilter { nearest, linear }

enum TargetFormat { rgba8, rgba16f }

enum CoverageMaskMode { hard, soft }

/// A producer-authored coverage texture and projective clip-to-texture map.
/// Nested masks may be composed into a target before its consumers are drawn.
final class CoverageMask {
  CoverageMask({
    required this.texture,
    required Float32List clipToMaskUv,
    this.mode = CoverageMaskMode.hard,
    required this.threshold,
  }) : clipToMaskUv = Float32List.fromList(clipToMaskUv).asUnmodifiableView() {
    if (texture.isEmpty ||
        clipToMaskUv.length != 16 ||
        clipToMaskUv.any((v) => !v.isFinite) ||
        !threshold.isFinite ||
        threshold < 0 ||
        threshold > 1) {
      throw ArgumentError('Invalid coverage mask');
    }
  }
  final String texture;
  final Float32List clipToMaskUv;
  final CoverageMaskMode mode;
  final double threshold;
}

/// Native renderer ingress: clip-space xyzw, UV and display-space RGBA, 10 floats/vertex.
/// Producer owns camera projection and preserves homogeneous W for perspective UV.
final class GeometryBuffer {
  GeometryBuffer(
    Float32List vertices,
    Uint16List indices, {
    this.layout = VertexLayout.sprite,
  }) : vertices = Float32List.fromList(vertices).asUnmodifiableView(),
       indices = Uint16List.fromList(indices).asUnmodifiableView() {
    if (vertices.length % strideFloats != 0 ||
        vertices.any((v) => !v.isFinite) ||
        indices.length % 3 != 0 ||
        indices.any((i) => i >= vertices.length ~/ strideFloats)) {
      throw ArgumentError('Invalid projected triangle mesh');
    }
  }
  GeometryBuffer._generated(Float32List vertices, TriangleTopology topology)
    : vertices = vertices.asUnmodifiableView(),
      indices = topology.indices,
      layout = VertexLayout.sprite {
    for (var i = 0; i < vertices.length; i++) {
      if (!vertices[i].isFinite) {
        throw ArgumentError('Invalid projected triangle mesh');
      }
    }
  }
  final Float32List vertices;
  final Uint16List indices;
  final VertexLayout layout;
  int get strideFloats => layout.strideFloats;
}

/// Immutable triangle indices may be shared by changing vertex frames.
final class TriangleTopology {
  TriangleTopology(Uint16List source)
    : indices = Uint16List.fromList(source).asUnmodifiableView() {
    if (indices.length % 3 != 0) {
      throw ArgumentError('Invalid triangle topology');
    }
    var maximum = -1;
    for (final index in indices) {
      if (index > maximum) maximum = index;
    }
    maximumIndex = maximum;
  }
  final Uint16List indices;
  late final int maximumIndex;

  bool matches(Uint16List source) {
    if (source.length != indices.length) return false;
    for (var i = 0; i < source.length; i++) {
      if (source[i] != indices[i]) return false;
    }
    return true;
  }
}

/// Owns its writable storage until build. Scalar writes never expose an alias
/// to the buffer that becomes the immutable render snapshot.
final class SpriteGeometryBuilder {
  SpriteGeometryBuilder({required int vertexCount, required this.topology})
    : _vertices = Float32List(vertexCount * VertexLayout.sprite.strideFloats) {
    if (topology.maximumIndex >= vertexCount) {
      throw ArgumentError('Invalid projected triangle mesh');
    }
  }
  final TriangleTopology topology;
  Float32List? _vertices;

  void setVertex(
    int index,
    double x,
    double y,
    double z,
    double w,
    double u,
    double v,
    double red,
    double green,
    double blue,
    double alpha,
  ) {
    final output = _vertices;
    if (output == null) throw StateError('Geometry builder already consumed');
    final offset = index * VertexLayout.sprite.strideFloats;
    output[offset] = x;
    output[offset + 1] = y;
    output[offset + 2] = z;
    output[offset + 3] = w;
    output[offset + 4] = u;
    output[offset + 5] = v;
    output[offset + 6] = red;
    output[offset + 7] = green;
    output[offset + 8] = blue;
    output[offset + 9] = alpha;
  }

  GeometryBuffer build() {
    final output = _vertices;
    if (output == null) throw StateError('Geometry builder already consumed');
    _vertices = null;
    return GeometryBuffer._generated(output, topology);
  }
}

final class VertexLayout {
  const VertexLayout(this.id, this.strideFloats);
  static const sprite = VertexLayout('sprite', 10);
  final String id;
  final int strideFloats;
}

final class TextureSampler {
  const TextureSampler({
    this.widthAddressMode = SamplerAddress.clampToEdge,
    this.heightAddressMode = SamplerAddress.clampToEdge,
    this.minFilter = SamplerFilter.linear,
    this.magFilter = SamplerFilter.linear,
  });
  final SamplerAddress widthAddressMode, heightAddressMode;
  final SamplerFilter minFilter, magFilter;
}

final class DrawMaterial {
  DrawMaterial({
    required this.programId,
    Map<String, String> textures = const {},
    Map<String, Float32List> uniforms = const {},
    Map<String, TextureSampler> samplers = const {},
    Map<String, TextureAlpha> expectedTextureAlpha = const {},
    this.blend = DrawBlend.premultipliedAlpha,
    this.depthTest = false,
    this.depthWrite = false,
    this.cull = DrawCull.none,
  }) : textures = Map.unmodifiable(textures),
       uniforms = Map.unmodifiable(uniforms),
       samplers = Map.unmodifiable(samplers),
       expectedTextureAlpha = Map.unmodifiable(expectedTextureAlpha);
  final String programId;
  final Map<String, String> textures;
  final Map<String, Float32List> uniforms;
  final Map<String, TextureSampler> samplers;
  final Map<String, TextureAlpha> expectedTextureAlpha;
  final DrawBlend blend;
  final bool depthTest, depthWrite;
  final DrawCull cull;
}

enum ShaderBindingStage { vertex, fragment }

final class ShaderProgramSpec {
  ShaderProgramSpec({
    required this.vertexEntry,
    required this.fragmentEntry,
    this.vertexStrideFloats = 10,
    this.required = false,
    Map<String, int> uniformFloatCounts = const {},
    Set<String> textureSlots = const {},
    Map<String, ShaderBindingStage> uniformStages = const {},
    Map<String, ShaderBindingStage> textureStages = const {},
    Set<ColorEncoding> acceptedTextureEncodings = const {
      ColorEncoding.gammaSrgb,
    },
    Set<TextureOrigin> acceptedTextureOrigins = const {TextureOrigin.topLeft},
  }) : uniformFloatCounts = Map.unmodifiable(uniformFloatCounts),
       textureSlots = Set.unmodifiable(textureSlots),
       uniformStages = Map.unmodifiable(uniformStages),
       textureStages = Map.unmodifiable(textureStages),
       acceptedTextureEncodings = Set.unmodifiable(acceptedTextureEncodings),
       acceptedTextureOrigins = Set.unmodifiable(acceptedTextureOrigins);
  final String vertexEntry, fragmentEntry;
  final int vertexStrideFloats;
  final bool required;
  final Map<String, int> uniformFloatCounts;
  final Set<String> textureSlots;
  final Map<String, ShaderBindingStage> uniformStages, textureStages;
  final Set<ColorEncoding> acceptedTextureEncodings;
  final Set<TextureOrigin> acceptedTextureOrigins;
}

final class RenderDraw {
  const RenderDraw({required this.mesh, required this.material});
  final String mesh, material;
}

/// Pass order and draw order are authored; no transparent texture regrouping.
final class RenderPass {
  RenderPass({
    required this.target,
    required List<RenderDraw> draws,
    this.clear = true,
    this.clearColor,
  }) : draws = List.unmodifiable(draws);
  final String target;
  final List<RenderDraw> draws;
  final bool clear;
  final Float32List? clearColor;
}

final class RenderTarget {
  const RenderTarget({
    required this.width,
    required this.height,
    this.format = TargetFormat.rgba8,
    this.depth = false,
    this.encoding = ColorEncoding.gammaSrgb,
    this.presentable = false,
    this.alpha = TextureAlpha.premultiplied,
  });
  final int width, height;
  final TargetFormat format;
  final ColorEncoding encoding;
  final bool depth;
  final bool presentable;
  final TextureAlpha alpha;
}

final class RenderScene {
  RenderScene({
    required this.epoch,
    required this.resourceScopeKey,
    required Map<String, GeometryBuffer> meshes,
    required Map<String, DrawMaterial> materials,
    required Map<String, RenderTarget> targets,
  }) : meshes = Map.unmodifiable(meshes),
       materials = Map.unmodifiable(materials),
       targets = Map.unmodifiable(targets);
  final int epoch;
  final String resourceScopeKey;
  final Map<String, GeometryBuffer> meshes;
  final Map<String, DrawMaterial> materials;
  final Map<String, RenderTarget> targets;
}

final class RenderFrame {
  RenderFrame({
    required this.epoch,
    required this.mediaMicroseconds,
    required this.outputTarget,
    required List<RenderPass> passes,
  }) : passes = List.unmodifiable(passes);
  final int epoch, mediaMicroseconds;
  final String outputTarget;
  final List<RenderPass> passes;
}
