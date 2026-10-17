import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'package:render_contracts/render_contracts.dart';

/// Resource-driven offscreen GPU backend. The host owns presentation surfaces and clocks.
/// The caller supplies shader bytes and named numeric binding contracts.
final class GpuFrameRenderer {
  GpuFrameRenderer(
    this.context, {
    required Map<String, ShaderProgramSpec> programs,
  }) : programSpecs = Map.unmodifiable(programs);
  final Map<String, ShaderProgramSpec> programSpecs;
  final gpu.GpuContext context;
  gpu.DeviceBuffer _copyBuffer(ByteData data) {
    final buffer = context.createDeviceBufferWithCopy(data);
    buffer.flush(offsetInBytes: 0, lengthInBytes: data.lengthInBytes);
    return buffer;
  }

  bool _stageBuffer(gpu.DeviceBuffer buffer, ByteData data) {
    if (!buffer.overwrite(data)) return false;
    buffer.flush(offsetInBytes: 0, lengthInBytes: data.lengthInBytes);
    return true;
  }

  final Map<String, (gpu.RenderPipeline, gpu.Shader, gpu.Shader)> _programs =
      {};
  final Map<String, (gpu.Shader, gpu.Shader)> _shaders = {};
  final Map<(String, ShaderBindingStage, String), gpu.UniformSlot>
  _shaderSlots = {};
  final Map<(String, String), gpu.BufferView> _uniformBuffers = {};
  final Map<String, ui.Image> _imageLeases = {};
  RenderScene? _scene;
  final Map<String, (gpu.BufferView, gpu.BufferView, int)> _meshes = {};
  final Map<String, GeometryBuffer> _uploadedMeshes = {};
  final Map<String, gpu.Texture> _textures = {};
  final Map<String, gpu.Texture> _depth = {};
  final Map<String, gpu.GpuImageSurface> _surfaces = {};
  final Map<String, TextureDescriptor> _textureDescriptors = {};
  Map<String, TextureDescriptor> get textureDescriptors =>
      Map.unmodifiable(_textureDescriptors);
  Map<String, Map<String, Object>> get textureResources => {
    for (final entry in _textures.entries)
      entry.key: {
        'width': entry.value.width,
        'height': entry.value.height,
        'format': entry.value.format.name,
        'mipLevels': entry.value.mipLevelCount,
        'texelBytes': _textureTexelBytes(entry.value),
        'target': _scene?.targets.containsKey(entry.key) ?? false,
        'materialReferences':
            _scene?.materials.values
                .where((material) => material.textures.containsValue(entry.key))
                .length ??
            0,
      },
  };
  Map<String, Map<String, Object>> get targetResources => {
    for (final entry
        in _scene?.targets.entries ?? const <MapEntry<String, RenderTarget>>[])
      entry.key: {
        'width': entry.value.width,
        'height': entry.value.height,
        'format': entry.value.format.name,
        'presentable': entry.value.presentable,
        'colourTexelBytes':
            entry.value.width *
            entry.value.height *
            (entry.value.format == TargetFormat.rgba16f ? 8 : 4),
        'depthTexelBytes': _depth[entry.key] == null
            ? 0
            : _textureTexelBytes(_depth[entry.key]!),
        'surfaceBackingTextures':
            _surfaces[entry.key]?.debugBackingTextureCount ?? 0,
      },
  };
  bool _inFlight = false;
  bool _disposed = false;
  int _resourceGeneration = 0;
  final Set<String> _initializedTargets = {};
  int _targetAllocations = 0, _targetReuses = 0;
  int _shaderSlotCreates = 0;
  int _vertexUploads = 0, _indexUploads = 0;
  int _vertexUploadSkips = 0, _indexUploadSkips = 0;
  int _uploadedVertexBytes = 0, _uploadedIndexBytes = 0;

  gpu.UniformSlot _shaderSlot(
    String programId,
    ShaderBindingStage stage,
    String name,
  ) => _shaderSlots.putIfAbsent((programId, stage, name), () {
    ++_shaderSlotCreates;
    final program = _programs[programId]!;
    return (stage == ShaderBindingStage.vertex ? program.$2 : program.$3)
        .getUniformSlot(name);
  });

  static bool _sameBytes(TypedData left, TypedData right) {
    if (identical(left, right)) return true;
    final length = left.lengthInBytes;
    if (length != right.lengthInBytes) return false;
    final words = length ~/ 4;
    final a = left.buffer.asUint32List(left.offsetInBytes, words);
    final b = right.buffer.asUint32List(right.offsetInBytes, words);
    for (var i = 0; i < words; i++) {
      if (a[i] != b[i]) return false;
    }
    final tail = length % 4;
    if (tail != 0) {
      final a = left.buffer.asUint8List(left.offsetInBytes + words * 4, tail);
      final b = right.buffer.asUint8List(right.offsetInBytes + words * 4, tail);
      for (var i = 0; i < tail; i++) {
        if (a[i] != b[i]) return false;
      }
    }
    return true;
  }

  Future<void> installShaders(ByteData bundle) async {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    final generation = _resourceGeneration;
    final library = await gpu.ShaderLibrary.fromBytes(bundle);
    if (_disposed || generation != _resourceGeneration)
      throw StateError('gpu_shader_source_replaced');
    if (library == null) throw StateError('gpu_shader_bundle_invalid');
    final next = <String, (gpu.Shader, gpu.Shader)>{};
    for (final entry in programSpecs.entries) {
      final spec = entry.value;
      final vertex = library[spec.vertexEntry];
      final fragment = library[spec.fragmentEntry];
      if (vertex == null || fragment == null) {
        if (spec.required)
          throw StateError('gpu_shader_program_missing:${entry.key}');
        continue;
      }
      next[entry.key] = (vertex, fragment);
    }
    if (_disposed || generation != _resourceGeneration)
      throw StateError('gpu_shader_source_replaced');
    _shaders
      ..clear()
      ..addAll(next);
    _programs.clear();
    _shaderSlots.clear();
  }

  /// Decoded straight-alpha RGBA8 pixels; network/image decoding is done by host.
  void installDecodedImage(String key, ui.Image image) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    _textures[key] = gpu.Texture.fromImage(context, image);
    _imageLeases.remove(key)?.dispose();
    _imageLeases[key] = image.clone();
    _textureDescriptors[key] = TextureDescriptor(
      width: image.width,
      height: image.height,
      alpha: TextureAlpha.premultiplied,
    );
  }

  void installTexture(String key, int width, int height, ByteData rgba) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    if (width <= 0 || height <= 0 || rgba.lengthInBytes != width * height * 4) {
      throw ArgumentError('gpu_invalid_texture');
    }
    final texture = context.createTexture(
      gpu.StorageMode.hostVisible,
      width,
      height,
      enableRenderTargetUsage: false,
    );
    texture.overwrite(rgba);
    _textures[key] = texture;
    _textureDescriptors[key] = TextureDescriptor(
      width: width,
      height: height,
      alpha: TextureAlpha.straight,
    );
  }

  /// Retire source inputs after the producer has removed their material bindings.
  void releaseTextures(Iterable<String> keys) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    final requested = keys.toSet();
    for (final key in requested) {
      if ((_scene?.targets.containsKey(key) ?? false) ||
          (_scene?.materials.values.any(
                (material) => material.textures.containsValue(key),
              ) ??
              false)) {
        throw StateError('gpu_texture_still_referenced:$key');
      }
    }
    for (final key in requested) {
      _textures.remove(key);
      _textureDescriptors.remove(key);
      _imageLeases.remove(key)?.dispose();
    }
  }

  /// Lossless native texel upload through the official batched command API.
  /// Source data/mask channels bypass UIImage premultiplication entirely.
  Future<void> installTextureData(
    String key,
    int width,
    int height,
    Uint8List rgba, {
    TextureAlpha alpha = TextureAlpha.straight,
    ColorEncoding encoding = ColorEncoding.gammaSrgb,
    TargetFormat format = TargetFormat.rgba8,
  }) async {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    if (_inFlight ||
        width <= 0 ||
        height <= 0 ||
        rgba.length !=
            width * height * (format == TargetFormat.rgba16f ? 8 : 4)) {
      throw ArgumentError('gpu_texture_data_scope');
    }
    final generation = _resourceGeneration;
    final pixelFormat = format == TargetFormat.rgba16f
        ? gpu.PixelFormat.r16g16b16a16Float
        : gpu.PixelFormat.r8g8b8a8UNormInt;
    if (!context.supportsTextureFormat(pixelFormat)) {
      throw UnsupportedError('gpu_texture_format_unavailable:$pixelFormat');
    }
    final texture = context.createTexture(
      gpu.StorageMode.devicePrivate,
      width,
      height,
      format: pixelFormat,
      enableRenderTargetUsage: false,
    );
    final buffer = _copyBuffer(ByteData.sublistView(rgba));
    final commands = context.createCommandBuffer();
    commands.copyBufferToTexture(
      gpu.BufferView(buffer, offsetInBytes: 0, lengthInBytes: rgba.length),
      gpu.TextureRegion(texture),
    );
    final completion = Completer<void>();
    commands.submit(
      completionCallback: (ok) {
        if (ok) {
          completion.complete();
        } else {
          completion.completeError(
            StateError('gpu_texture_data_upload_failed'),
          );
        }
      },
    );
    await completion.future;
    if (generation != _resourceGeneration) {
      throw StateError('gpu_texture_source_replaced');
    }
    _imageLeases.remove(key)?.dispose();
    _textures[key] = texture;
    _textureDescriptors[key] = TextureDescriptor(
      width: width,
      height: height,
      alpha: alpha,
      encoding: encoding,
      format: format,
    );
  }

  /// Dynamic geometry updates retain native buffer allocations and authored order.
  void updateMesh(String key, GeometryBuffer mesh, int epoch) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    if (_inFlight || _scene?.epoch != epoch) {
      throw StateError('gpu_mesh_update_epoch_or_busy');
    }
    final current = _meshes[key];
    if (current == null ||
        current.$1.buffer.sizeInBytes < mesh.vertices.lengthInBytes ||
        current.$2.buffer.sizeInBytes < mesh.indices.lengthInBytes) {
      throw StateError('gpu_mesh_capacity_changed_reinstall_required');
    }
    // GeometryBuffer snapshots own immutable bytes, including SDK-derived data.
    // Compare against the last upload, not a potentially older scene descriptor.
    final uploaded = _uploadedMeshes[key];
    final vertexChanged =
        uploaded == null || !_sameBytes(uploaded.vertices, mesh.vertices);
    final indexChanged =
        uploaded == null || !_sameBytes(uploaded.indices, mesh.indices);
    if (vertexChanged) {
      if (!_stageBuffer(
        current.$1.buffer,
        ByteData.sublistView(mesh.vertices),
      )) {
        _uploadedMeshes.remove(key);
        throw StateError('gpu_mesh_upload_failed');
      }
      ++_vertexUploads;
      _uploadedVertexBytes += mesh.vertices.lengthInBytes;
    } else {
      ++_vertexUploadSkips;
    }
    if (indexChanged) {
      if (!_stageBuffer(
        current.$2.buffer,
        ByteData.sublistView(mesh.indices),
      )) {
        _uploadedMeshes.remove(key);
        throw StateError('gpu_mesh_upload_failed');
      }
      ++_indexUploads;
      _uploadedIndexBytes += mesh.indices.lengthInBytes;
    } else {
      ++_indexUploadSkips;
    }
    _meshes[key] = (
      vertexChanged
          ? gpu.BufferView(
              current.$1.buffer,
              offsetInBytes: 0,
              lengthInBytes: mesh.vertices.lengthInBytes,
            )
          : current.$1,
      indexChanged
          ? gpu.BufferView(
              current.$2.buffer,
              offsetInBytes: 0,
              lengthInBytes: mesh.indices.lengthInBytes,
            )
          : current.$2,
      mesh.indices.length,
    );
    _uploadedMeshes[key] = mesh;
  }

  /// Frame-resource updates reuse all textures, targets and shader programs.
  /// A source/viewport change must use installScene instead of crossing epochs.
  void updateSceneResources(RenderScene next) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    final previous = _scene;
    if (_inFlight ||
        previous == null ||
        previous.epoch != next.epoch ||
        previous.resourceScopeKey != next.resourceScopeKey) {
      throw StateError('gpu_frame_resource_source_changed');
    }
    var targetChanged = previous.targets.length != next.targets.length;
    for (final entry in next.targets.entries) {
      final old = previous.targets[entry.key], value = entry.value;
      if (old == null ||
          old.width != value.width ||
          old.height != value.height ||
          old.format != value.format ||
          old.depth != value.depth ||
          old.presentable != value.presentable ||
          old.alpha != value.alpha ||
          old.encoding != value.encoding) {
        targetChanged = true;
      }
    }
    // A model may add or retire clipping masks inside the same source epoch.
    // Rebuild that graph only after the previous submission has completed.
    if (targetChanged) {
      installScene(next);
      return;
    }
    for (final material in next.materials.values) {
      for (final texture in material.textures.values) {
        if (!_textures.containsKey(texture))
          throw StateError('gpu_frame_texture_not_installed:$texture');
      }
    }
    for (final entry in next.meshes.entries) {
      final mesh = entry.value, current = _meshes[entry.key];
      if (mesh.vertices.isEmpty || mesh.indices.isEmpty) continue;
      if (current != null &&
          current.$1.buffer.sizeInBytes >= mesh.vertices.lengthInBytes &&
          current.$2.buffer.sizeInBytes >= mesh.indices.lengthInBytes) {
        updateMesh(entry.key, mesh, next.epoch);
      } else {
        int capacity(int requested) {
          var bytes = 256;
          while (bytes < requested) {
            bytes *= 2;
          }
          return bytes;
        }

        final vb = context.createDeviceBuffer(
              gpu.StorageMode.hostVisible,
              capacity(mesh.vertices.lengthInBytes),
            ),
            ib = context.createDeviceBuffer(
              gpu.StorageMode.hostVisible,
              capacity(mesh.indices.lengthInBytes),
            );
        if (!_stageBuffer(vb, ByteData.sublistView(mesh.vertices)) ||
            !_stageBuffer(ib, ByteData.sublistView(mesh.indices))) {
          throw StateError('gpu_mesh_capacity_upload_failed');
        }
        _meshes[entry.key] = (
          gpu.BufferView(
            vb,
            offsetInBytes: 0,
            lengthInBytes: mesh.vertices.lengthInBytes,
          ),
          gpu.BufferView(
            ib,
            offsetInBytes: 0,
            lengthInBytes: mesh.indices.lengthInBytes,
          ),
          mesh.indices.length,
        );
        _uploadedMeshes[entry.key] = mesh;
        ++_vertexUploads;
        ++_indexUploads;
        _uploadedVertexBytes += mesh.vertices.lengthInBytes;
        _uploadedIndexBytes += mesh.indices.lengthInBytes;
      }
    }
    // Submission completion has released the previous frame's mesh reads.
    // Presentable UI images retain only their output texture, not these inputs.
    _meshes.removeWhere(
      (key, _) =>
          !next.meshes.containsKey(key) ||
          next.meshes[key]!.vertices.isEmpty ||
          next.meshes[key]!.indices.isEmpty,
    );
    _uploadedMeshes.removeWhere((key, _) => !_meshes.containsKey(key));
    _uniformBuffers.removeWhere(
      (key, _) => !next.materials.containsKey(key.$1),
    );
    _scene = next;
  }

  Map<String, int> get resourceCounts => {
    'shaderProgramsAvailable': _shaders.length,
    'shaderProgramsRegistered': _programs.length,
    'shaderSlots': _shaderSlots.length,
    'shaderSlotCreates': _shaderSlotCreates,
    'vertexUploads': _vertexUploads,
    'indexUploads': _indexUploads,
    'vertexUploadSkips': _vertexUploadSkips,
    'indexUploadSkips': _indexUploadSkips,
    'uploadedVertexBytes': _uploadedVertexBytes,
    'uploadedIndexBytes': _uploadedIndexBytes,
    'meshes': _meshes.length,
    'uniformBuffers': _uniformBuffers.length,
    'allocatedUniformBytes': _uniformBuffers.values.fold(
      0,
      (bytes, view) => bytes + view.buffer.sizeInBytes,
    ),
    'textures': _textures.length,
    'textureTexelBytes': _textures.values.fold(
      0,
      (bytes, texture) => bytes + _textureTexelBytes(texture),
    ),
    'depthTexelBytes': _depth.values.fold(
      0,
      (bytes, texture) => bytes + _textureTexelBytes(texture),
    ),
    'targets': _scene?.targets.length ?? 0,
    'targetAllocations': _targetAllocations,
    'targetReuses': _targetReuses,
    'imageLeases': _imageLeases.length,
    'surfaceBackingTextures': _surfaces.values.fold(
      0,
      (count, surface) => count + surface.debugBackingTextureCount,
    ),
    'surfaces': _surfaces.length,
    'vertexBytes': _meshes.values.fold(
      0,
      (n, mesh) => n + mesh.$1.lengthInBytes,
    ),
    'indexBytes': _meshes.values.fold(
      0,
      (n, mesh) => n + mesh.$2.lengthInBytes,
    ),
    'allocatedVertexBytes': _meshes.values.fold(
      0,
      (total, mesh) => total + mesh.$1.buffer.sizeInBytes,
    ),
    'allocatedIndexBytes': _meshes.values.fold(
      0,
      (total, mesh) => total + mesh.$2.buffer.sizeInBytes,
    ),
  };

  static int _textureTexelBytes(gpu.Texture texture) {
    var bytes = 0;
    for (var mip = 0; mip < texture.mipLevelCount; mip++) {
      bytes += texture.getMipLevelSizeInBytes(mip);
    }
    return bytes * texture.sliceCount * texture.sampleCount;
  }

  void clearResources() {
    ++_resourceGeneration;
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    _scene = null;
    for (final image in _imageLeases.values) {
      image.dispose();
    }
    _imageLeases.clear();
    _initializedTargets.clear();
    _meshes.clear();
    _uploadedMeshes.clear();
    _shaderSlots.clear();
    _uniformBuffers.clear();
    _textures.clear();
    _surfaces.clear();
    _textureDescriptors.clear();
    _depth.clear();
  }

  void installScene(RenderScene scene) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    final old = _scene;
    final reuseSource =
        old != null &&
        old.epoch == scene.epoch &&
        old.resourceScopeKey == scene.resourceScopeKey;
    final oldTargets = old?.targets ?? const <String, RenderTarget>{};
    final meshes = <String, (gpu.BufferView, gpu.BufferView, int)>{};
    final targets = <String, gpu.Texture>{};
    final depth = <String, gpu.Texture>{};
    final surfaces = <String, gpu.GpuImageSurface>{};
    final retainedTargets = <String>{};
    for (final entry in scene.meshes.entries) {
      final v = entry.value.vertices;
      final i = entry.value.indices;
      if (v.isEmpty || i.isEmpty) continue;
      final previous = reuseSource ? _meshes[entry.key] : null;
      if (previous != null &&
          previous.$1.buffer.sizeInBytes >= v.lengthInBytes &&
          previous.$2.buffer.sizeInBytes >= i.lengthInBytes) {
        updateMesh(entry.key, entry.value, scene.epoch);
        meshes[entry.key] = _meshes[entry.key]!;
        continue;
      }
      final vb = _copyBuffer(ByteData.sublistView(v));
      final ib = _copyBuffer(ByteData.sublistView(i));
      meshes[entry.key] = (
        gpu.BufferView(vb, offsetInBytes: 0, lengthInBytes: v.lengthInBytes),
        gpu.BufferView(ib, offsetInBytes: 0, lengthInBytes: i.lengthInBytes),
        i.length,
      );
      ++_vertexUploads;
      ++_indexUploads;
      _uploadedVertexBytes += v.lengthInBytes;
      _uploadedIndexBytes += i.lengthInBytes;
    }
    for (final entry in scene.targets.entries) {
      final spec = entry.value;
      if (spec.presentable && spec.alpha != TextureAlpha.premultiplied) {
        throw UnsupportedError('gpu_surface_requires_premultiplied');
      }
      if (_textures.containsKey(entry.key) &&
          !(_scene?.targets.containsKey(entry.key) ?? false)) {
        throw StateError('gpu_target_texture_key_collision');
      }
      if (spec.width <= 0 || spec.height <= 0) {
        throw ArgumentError('gpu_invalid_target_size');
      }
      final previous = reuseSource ? oldTargets[entry.key] : null;
      if (previous != null &&
          previous.width == spec.width &&
          previous.height == spec.height &&
          previous.format == spec.format &&
          previous.depth == spec.depth &&
          previous.presentable == spec.presentable &&
          previous.alpha == spec.alpha &&
          previous.encoding == spec.encoding) {
        if (spec.presentable) {
          surfaces[entry.key] = _surfaces[entry.key]!;
        } else {
          targets[entry.key] = _textures[entry.key]!;
        }
        if (spec.depth) depth[entry.key] = _depth[entry.key]!;
        retainedTargets.add(entry.key);
        _targetReuses++;
        continue;
      }
      final format = spec.format == TargetFormat.rgba16f
          ? gpu.PixelFormat.r16g16b16a16Float
          : gpu.PixelFormat.r8g8b8a8UNormInt;
      if (!context.supportsTextureFormat(format, renderTarget: true)) {
        throw UnsupportedError('gpu_target_format_unavailable:$format');
      }
      if (spec.presentable) {
        if (spec.depth) throw ArgumentError('gpu_surface_depth_target');
        surfaces[entry.key] = context.createImageSurface(
          spec.width,
          spec.height,
          format: format,
        );
      } else {
        targets[entry.key] = context.createTexture(
          gpu.StorageMode.devicePrivate,
          spec.width,
          spec.height,
          format: format,
        );
      }
      _targetAllocations++;
      if (spec.depth) {
        final format = context.defaultDepthStencilFormat;
        if (format == gpu.PixelFormat.unknown) {
          throw UnsupportedError('gpu_depth_stencil_unavailable');
        }
        depth[entry.key] = context.createTexture(
          gpu.StorageMode.devicePrivate,
          spec.width,
          spec.height,
          format: format,
          enableShaderReadUsage: false,
        );
      }
    }
    for (final material in scene.materials.values) {
      for (final texture in material.textures.values) {
        if (!_textures.containsKey(texture) && !targets.containsKey(texture)) {
          throw StateError('gpu_material_texture_missing:$texture');
        }
      }
    }
    for (final key in oldTargets.keys) {
      _textures.remove(key);
      _textureDescriptors.remove(key);
    }
    _textures.addAll(targets);
    for (final entry in scene.targets.entries) {
      _textureDescriptors[entry.key] = TextureDescriptor(
        width: entry.value.width,
        height: entry.value.height,
        alpha: entry.value.alpha,
        encoding: entry.value.encoding,
        format: entry.value.format,
      );
    }
    _meshes
      ..clear()
      ..addAll(meshes);
    _uploadedMeshes
      ..clear()
      ..addEntries(meshes.keys.map((key) => MapEntry(key, scene.meshes[key]!)));
    _depth
      ..clear()
      ..addAll(depth);
    _surfaces
      ..clear()
      ..addAll(surfaces);
    _initializedTargets.removeWhere((key) => !retainedTargets.contains(key));
    _uniformBuffers.removeWhere(
      (key, _) => !scene.materials.containsKey(key.$1),
    );
    _scene = scene;
  }

  ui.Image resourceImage(String key) {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    final surfaceImage = _surfaces[key]?.currentImage;
    if (surfaceImage != null) return surfaceImage;
    final texture = _textures[key];
    if (texture == null) throw StateError('gpu_resource_image_missing');
    return texture.asImage();
  }

  Future<ui.Image> render(RenderFrame frame) async {
    if (_disposed) throw StateError('gpu_renderer_disposed');
    final scene = _scene;
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    if (scene == null || _shaders.isEmpty || frame.epoch != scene.epoch) {
      throw StateError('gpu_renderer_not_ready_or_epoch_mismatch');
    }
    if (frame.mediaMicroseconds < 0 ||
        !scene.targets.containsKey(frame.outputTarget)) {
      throw ArgumentError('gpu_invalid_frame');
    }
    _inFlight = true;
    gpu.GpuSurfaceFrame? surfaceFrame;
    try {
      final command = context.createCommandBuffer();
      final surface = _surfaces[frame.outputTarget];
      surfaceFrame = surface?.acquireNextFrame();
      final initialized = {..._initializedTargets};
      final writtenTargets = <String>{};
      for (final spec in frame.passes) {
        final target = spec.target == frame.outputTarget && surfaceFrame != null
            ? surfaceFrame.colorTexture
            : _textures[spec.target];
        if (target == null || !scene.targets.containsKey(spec.target)) {
          throw StateError('gpu_target_missing');
        }
        if (!spec.clear && !initialized.contains(spec.target)) {
          throw StateError('gpu_uninitialized_target_load');
        }
        if (scene.targets[spec.target]!.presentable && !spec.clear) {
          throw StateError('gpu_surface_requires_clear');
        }
        final depth = _depth[spec.target];
        final pass = command.createRenderPass(
          gpu.RenderTarget.singleColor(
            gpu.ColorAttachment(
              texture: target,
              clearValue: spec.clearColor == null
                  ? vm.Vector4.zero()
                  : vm.Vector4(
                      spec.clearColor![0],
                      spec.clearColor![1],
                      spec.clearColor![2],
                      spec.clearColor![3],
                    ),
              loadAction: spec.clear
                  ? gpu.LoadAction.clear
                  : gpu.LoadAction.load,
            ),
            depthStencilAttachment: depth == null
                ? null
                : gpu.DepthStencilAttachment(
                    texture: depth,
                    depthClearValue: 1,
                    depthLoadAction: spec.clear
                        ? gpu.LoadAction.clear
                        : gpu.LoadAction.load,
                    depthStoreAction: gpu.StoreAction.store,
                  ),
          ),
        );
        for (final draw in spec.draws) {
          final mesh = _meshes[draw.mesh];
          final material = scene.materials[draw.material];
          if (mesh == null || material == null) {
            throw StateError('gpu_draw_resource_missing');
          }
          if ((material.depthTest || material.depthWrite) && depth == null)
            throw StateError('gpu_draw_requires_depth');
          final definition = programSpecs[material.programId];
          final shaders = _shaders[material.programId];
          if (definition == null || shaders == null)
            throw StateError('gpu_program_not_installed:${material.programId}');
          final program = _programs.putIfAbsent(
            material.programId,
            () => (
              context.createRenderPipeline(shaders.$1, shaders.$2),
              shaders.$1,
              shaders.$2,
            ),
          );
          if (scene.meshes[draw.mesh]!.strideFloats !=
              definition.vertexStrideFloats)
            throw StateError(
              'gpu_vertex_layout_mismatch:${material.programId}',
            );
          pass.clearBindings();
          pass.bindPipeline(program.$1);
          pass.setCullMode(switch (material.cull) {
            DrawCull.none => gpu.CullMode.none,
            DrawCull.back => gpu.CullMode.backFace,
            DrawCull.front => gpu.CullMode.frontFace,
          });
          pass.setWindingOrder(gpu.WindingOrder.counterClockwise);
          pass.bindVertexBuffer(mesh.$1);
          pass.bindIndexBuffer(mesh.$2, gpu.IndexType.int16);
          for (final block in definition.uniformFloatCounts.entries) {
            final floats = material.uniforms[block.key];
            if (floats == null || floats.length != block.value)
              throw StateError(
                'gpu_uniform_layout:${material.programId}:${block.key}',
              );
            final key = (draw.material, block.key);
            var uniform = _uniformBuffers[key];
            if (uniform == null ||
                uniform.lengthInBytes != floats.lengthInBytes) {
              uniform = gpu.BufferView(
                _copyBuffer(ByteData.sublistView(floats)),
                offsetInBytes: 0,
                lengthInBytes: floats.lengthInBytes,
              );
              _uniformBuffers[key] = uniform;
            } else if (!_stageBuffer(
              uniform.buffer,
              ByteData.sublistView(floats),
            )) {
              throw StateError('gpu_uniform_upload:$key');
            }
            pass.bindUniform(
              _shaderSlot(
                material.programId,
                definition.uniformStages[block.key] ??
                    ShaderBindingStage.fragment,
                block.key,
              ),
              uniform,
            );
          }
          for (final slot in definition.textureSlots) {
            final key = material.textures[slot];
            final texture = _textures[key];
            final descriptor = _textureDescriptors[key];
            if (key == null || texture == null || descriptor == null)
              throw StateError('gpu_texture_binding_missing:$slot:$key');
            if (key == spec.target)
              throw StateError('gpu_texture_feedback:$key');
            if (scene.targets.containsKey(key) && !initialized.contains(key))
              throw StateError('gpu_uninitialized_target_sample:$key');
            if (!definition.acceptedTextureOrigins.contains(
                  descriptor.origin,
                ) ||
                !definition.acceptedTextureEncodings.contains(
                  descriptor.encoding,
                ))
              throw UnsupportedError('gpu_texture_format:$key');
            final alpha = material.expectedTextureAlpha[slot];
            if (alpha != null && descriptor.alpha != alpha)
              throw StateError('gpu_texture_alpha_mismatch:$key');
            final sampler = material.samplers[slot] ?? const TextureSampler();
            pass.bindTexture(
              _shaderSlot(
                material.programId,
                definition.textureStages[slot] ?? ShaderBindingStage.fragment,
                slot,
              ),
              texture,
              sampler: gpu.SamplerOptions(
                minFilter: switch (sampler.minFilter) {
                  SamplerFilter.nearest => gpu.MinMagFilter.nearest,
                  SamplerFilter.linear => gpu.MinMagFilter.linear,
                },
                magFilter: switch (sampler.magFilter) {
                  SamplerFilter.nearest => gpu.MinMagFilter.nearest,
                  SamplerFilter.linear => gpu.MinMagFilter.linear,
                },
                widthAddressMode: switch (sampler.widthAddressMode) {
                  SamplerAddress.clampToEdge =>
                    gpu.SamplerAddressMode.clampToEdge,
                  SamplerAddress.repeat => gpu.SamplerAddressMode.repeat,
                  SamplerAddress.mirror => gpu.SamplerAddressMode.mirror,
                },
                heightAddressMode: switch (sampler.heightAddressMode) {
                  SamplerAddress.clampToEdge =>
                    gpu.SamplerAddressMode.clampToEdge,
                  SamplerAddress.repeat => gpu.SamplerAddressMode.repeat,
                  SamplerAddress.mirror => gpu.SamplerAddressMode.mirror,
                },
              ),
            );
          }
          pass.setColorBlendEnable(material.blend != DrawBlend.opaque);
          final (
            sourceColor,
            destinationColor,
            sourceAlpha,
            destinationAlpha,
          ) = switch (material.blend) {
            DrawBlend.opaque => (
              gpu.BlendFactor.one,
              gpu.BlendFactor.zero,
              gpu.BlendFactor.one,
              gpu.BlendFactor.zero,
            ),
            DrawBlend.premultipliedAlpha => (
              gpu.BlendFactor.one,
              gpu.BlendFactor.oneMinusSourceAlpha,
              gpu.BlendFactor.one,
              gpu.BlendFactor.oneMinusSourceAlpha,
            ),
            DrawBlend.additive => (
              gpu.BlendFactor.one,
              gpu.BlendFactor.one,
              gpu.BlendFactor.one,
              gpu.BlendFactor.one,
            ),
            DrawBlend.additivePreserveAlpha => (
              gpu.BlendFactor.one,
              gpu.BlendFactor.one,
              gpu.BlendFactor.zero,
              gpu.BlendFactor.one,
            ),
            DrawBlend.multiply => (
              gpu.BlendFactor.destinationColor,
              gpu.BlendFactor.oneMinusSourceAlpha,
              gpu.BlendFactor.zero,
              gpu.BlendFactor.one,
            ),
            DrawBlend.sourceAlphaAdditive => (
              gpu.BlendFactor.sourceAlpha,
              gpu.BlendFactor.one,
              gpu.BlendFactor.sourceAlpha,
              gpu.BlendFactor.one,
            ),
            DrawBlend.coverageUnion => (
              gpu.BlendFactor.oneMinusDestinationColor,
              gpu.BlendFactor.one,
              gpu.BlendFactor.oneMinusDestinationAlpha,
              gpu.BlendFactor.one,
            ),
            DrawBlend.sourceAlpha => (
              gpu.BlendFactor.sourceAlpha,
              gpu.BlendFactor.oneMinusSourceAlpha,
              gpu.BlendFactor.sourceAlpha,
              gpu.BlendFactor.oneMinusSourceAlpha,
            ),
          };
          pass.setColorBlendEquation(
            gpu.ColorBlendEquation(
              sourceColorBlendFactor: sourceColor,
              destinationColorBlendFactor: destinationColor,
              sourceAlphaBlendFactor: sourceAlpha,
              destinationAlphaBlendFactor: destinationAlpha,
            ),
          );
          pass.setDepthWriteEnable(material.depthWrite);
          pass.setDepthCompareOperation(
            material.depthTest
                ? gpu.CompareFunction.lessEqual
                : gpu.CompareFunction.always,
          );
          pass.drawIndexed(mesh.$3);
        }
        initialized.add(spec.target);
        writtenTargets.add(spec.target);
      }
      if (!writtenTargets.contains(frame.outputTarget)) {
        throw StateError('gpu_output_not_rendered');
      }
      final completion = Completer<void>();
      surfaceFrame?.present(command);
      command.submit(
        completionCallback: (bool ok) {
          if (ok) {
            completion.complete();
          } else {
            completion.completeError(StateError('gpu_submission_failed'));
          }
        },
      );
      await completion.future;
      _initializedTargets
        ..clear()
        ..addAll(initialized);
      if (surface != null) {
        final image = surface.currentImage;
        if (image == null) throw StateError('gpu_surface_image_missing');
        return image;
      }
      return _textures[frame.outputTarget]!.asImage();
    } finally {
      surfaceFrame?.discard();
      _inFlight = false;
    }
  }

  /// Host disposes images it received; GPU wrappers release after references drop.
  void dispose() {
    if (_disposed) return;
    if (_inFlight) throw StateError('gpu_frame_in_flight');
    _disposed = true;
    ++_resourceGeneration;
    _scene = null;
    _surfaces.clear();
    _uniformBuffers.clear();
    for (final image in _imageLeases.values) {
      image.dispose();
    }
    _imageLeases.clear();
    _programs.clear();
    _shaders.clear();
    _shaderSlots.clear();
    _initializedTargets.clear();
    _meshes.clear();
    _uploadedMeshes.clear();
    _textures.clear();
    _textureDescriptors.clear();
    _depth.clear();
  }
}
