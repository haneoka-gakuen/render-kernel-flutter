import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:render_contracts/render_contracts.dart';

/// FSR 1 EASU followed by RCAS for an opaque, tone-mapped gamma RGB layer.
/// Native UI is composed by the host after [outputTarget]. The input's alpha
/// is independent and ignored; its producer must already have made it opaque.
final class SpatialUpscaler {
  const SpatialUpscaler({this.sharpnessStops = 0.2, this.sharpness});
  final double sharpnessStops;

  /// RCAS strength from 0 (off) to 1 (maximum). Overrides [sharpnessStops].
  final double? sharpness;
  static const bundleAsset =
      'packages/render_kernel_flutter/assets/shaders/spatial.shaderbundle';
  static Future<ByteData>? _shaderBytes;
  static Future<ByteData> loadShaders() => _shaderBytes ??= _loadShaders();
  static Future<ByteData> _loadShaders() async {
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(
        ['AMD FidelityFX FSR 1.0.2'],
        await rootBundle.loadString(
          'packages/render_kernel_flutter/LICENSE-FidelityFX-FSR.txt',
        ),
      );
    });
    return rootBundle.load(bundleAsset);
  }

  static final programs = <String, ShaderProgramSpec>{
    'spatial-fsr-easu': ShaderProgramSpec(
      vertexEntry: 'SpatialFullscreenVertex',
      fragmentEntry: 'SpatialFsrEasuFragment',
      required: true,
      textureSlots: {'image'},
      uniformFloatCounts: {'EasuSettings': 4},
    ),
    'spatial-fsr-rcas': ShaderProgramSpec(
      vertexEntry: 'SpatialFullscreenVertex',
      fragmentEntry: 'SpatialFsrRcasFragment',
      required: true,
      textureSlots: {'image'},
      uniformFloatCounts: {'RcasSettings': 4},
    ),
  };
  static (int, int) inputSize(int width, int height, double factor) {
    if (width <= 0 || height <= 0 || !factor.isFinite || factor < 1) {
      throw ArgumentError('Invalid spatial upscaling dimensions');
    }
    return (
      math.max(1, (width / factor).round()),
      math.max(1, (height / factor).round()),
    );
  }

  static final _quad = GeometryBuffer(
    Float32List.fromList([
      -1,
      1,
      0,
      1,
      0,
      0,
      1,
      1,
      1,
      1,
      -1,
      -1,
      0,
      1,
      0,
      1,
      1,
      1,
      1,
      1,
      1,
      -1,
      0,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      1,
      0,
      1,
      1,
      0,
      1,
      1,
      1,
      1,
    ]),
    Uint16List.fromList([0, 1, 2, 0, 2, 3]),
  );

  /// Insert the two passes immediately after the input's final writer.
  /// Existing downstream materials may refer to [outputTarget] already.
  ({RenderScene scene, RenderFrame frame}) append({
    required RenderScene scene,
    required RenderFrame frame,
    required String inputTarget,
    required String outputTarget,
    required int width,
    required int height,
    String namespace = 'spatial',
    bool presentable = false,
  }) {
    final source = scene.targets[inputTarget];
    if (source == null ||
        source.encoding != ColorEncoding.gammaSrgb ||
        source.format != TargetFormat.rgba8 ||
        source.alpha != TextureAlpha.independent ||
        source.depth ||
        width < source.width ||
        height < source.height ||
        !sharpnessStops.isFinite ||
        sharpnessStops < 0 ||
        sharpnessStops > 2 ||
        (sharpness != null &&
            (!sharpness!.isFinite || sharpness! < 0 || sharpness! > 1))) {
      throw ArgumentError(
        'Spatial input must be opaque tone-mapped gamma RGBA8',
      );
    }
    if (scene.epoch != frame.epoch || inputTarget == outputTarget) {
      throw ArgumentError('Invalid spatial frame boundary');
    }
    final intermediate = '$namespace:easu';
    final mesh = '$namespace:quad',
        easu = '$namespace:easu-material',
        rcas = '$namespace:rcas-material';
    if (scene.targets.containsKey(intermediate) ||
        scene.meshes.containsKey(mesh) ||
        scene.materials.containsKey(easu) ||
        scene.materials.containsKey(rcas)) {
      throw ArgumentError('Spatial namespace collision');
    }
    final existing = scene.targets[outputTarget];
    if (existing != null &&
        (existing.width != width ||
            existing.height != height ||
            existing.depth ||
            (existing.format != TargetFormat.rgba8 &&
                existing.format != TargetFormat.rgba16f) ||
            existing.encoding != ColorEncoding.gammaSrgb)) {
      throw ArgumentError('Spatial output target mismatch');
    }
    final lastWriter = frame.passes.lastIndexWhere(
      (p) => p.target == inputTarget,
    );
    if (lastWriter < 0 ||
        frame.passes.indexed.any(
          (entry) =>
              entry.$2.target == outputTarget &&
              (entry.$1 <= lastWriter || entry.$2.clear),
        )) {
      throw ArgumentError('Spatial target writer mismatch');
    }
    final firstConsumerPass = frame.passes.indexWhere(
      (pass) => pass.target == outputTarget,
    );
    // A load-only native UI pass can follow RCAS in the same attachment pass.
    // All shader sampler bindings, including Native coverage masks, are
    // normalized into DrawMaterial.textures before reaching RenderIR.
    // Keep separate passes when an intervening draw samples the output.
    final fuseOutput =
        firstConsumerPass > lastWriter &&
        frame.passes
            .skip(lastWriter + 1)
            .take(firstConsumerPass - lastWriter - 1)
            .every(
              (pass) => pass.draws.every(
                (draw) => !scene.materials[draw.material]!.textures.values
                    .contains(outputTarget),
              ),
            );
    DrawMaterial material(
      String program,
      String input,
      String block,
      List<double> values,
    ) => DrawMaterial(
      programId: program,
      textures: {'image': input},
      uniforms: {block: Float32List.fromList(values)},
      samplers: {
        'image': const TextureSampler(
          minFilter: SamplerFilter.nearest,
          magFilter: SamplerFilter.nearest,
        ),
      },
      expectedTextureAlpha: {'image': TextureAlpha.independent},
      blend: DrawBlend.opaque,
    );
    final targets = {
      ...scene.targets,
      intermediate: RenderTarget(
        width: width,
        height: height,
        alpha: TextureAlpha.independent,
      ),
      outputTarget: RenderTarget(
        width: width,
        height: height,
        format: existing?.format ?? TargetFormat.rgba8,
        // Opaque alpha=1 is valid for the consumer's existing alpha convention.
        alpha: existing?.alpha ?? TextureAlpha.independent,
        presentable: presentable || (existing?.presentable ?? false),
      ),
    };
    return (
      scene: RenderScene(
        epoch: scene.epoch,
        resourceScopeKey: scene.resourceScopeKey,
        meshes: {...scene.meshes, mesh: _quad},
        materials: {
          ...scene.materials,
          easu: material('spatial-fsr-easu', inputTarget, 'EasuSettings', [
            source.width.toDouble(),
            source.height.toDouble(),
            width.toDouble(),
            height.toDouble(),
          ]),
          rcas: material('spatial-fsr-rcas', intermediate, 'RcasSettings', [
            width.toDouble(),
            height.toDouble(),
            sharpness ?? math.pow(2, -sharpnessStops).toDouble(),
            0,
          ]),
        },
        targets: targets,
      ),
      frame: RenderFrame(
        epoch: frame.epoch,
        mediaMicroseconds: frame.mediaMicroseconds,
        outputTarget: frame.outputTarget,
        passes: [
          ...frame.passes.take(lastWriter + 1),
          RenderPass(
            target: intermediate,
            draws: [RenderDraw(mesh: mesh, material: easu)],
          ),
          if (!fuseOutput)
            RenderPass(
              target: outputTarget,
              draws: [RenderDraw(mesh: mesh, material: rcas)],
            ),
          for (final (index, pass) in frame.passes.indexed.skip(lastWriter + 1))
            if (fuseOutput && index == firstConsumerPass)
              RenderPass(
                target: pass.target,
                draws: [
                  RenderDraw(mesh: mesh, material: rcas),
                  ...pass.draws,
                ],
                clear: true,
                clearColor: pass.clearColor,
              )
            else
              pass,
        ],
      ),
    );
  }
}
