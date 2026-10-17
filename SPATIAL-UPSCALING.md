# Spatial upscaling

The optional `SpatialUpscaler` reconstructs an opaque, tone-mapped gamma RGB layer with AMD FidelityFX FSR 1.0.2 EASU and RCAS. The renderer accepts its independent shader bundle through `additionalShaderBundles`; ordinary RenderIR frames retain their existing shader library and behavior.

The host chooses the input dimensions with `inputSize`, writes the world layer into an independent-alpha RGBA8 gamma target with alpha 1, and calls `append` before native-resolution UI. Transparency, authored HDR effects, and bloom belong in the world composition before reconstruction. UI, text, and controls retain their full resolution. `sharpness` accepts a strength from 0 to 1; the default corresponds to 0.2 RCAS stops.

`append` adds EASU and RCAS draws. When the next output writer only loads the attachment and no intervening material samples it, RCAS shares that writer's pass. This also avoids Flutter's Vulkan attachment render-pass cache reusing a previous clear operation for a later load operation on the same texture. Other output dependencies retain separate passes.

The kernel has no application preferences or game dependencies. Hosts own presets, persistence, and whether reconstruction is enabled. A factor of 1 can retain the host's original rendering path.

The shipped bundle contains Vulkan, OpenGL ES, desktop OpenGL, Metal iOS, and Metal desktop programs. Rebuild it using Flutter's existing compiler:

```sh
node tool/build-shaders.mjs --compiler /absolute/path/to/impellerc
```

The GLSL wrappers can also be regenerated explicitly from the neutral `@haneoka/render-shaders` package shared with the Three renderers:

```sh
node tool/build-shaders.mjs --compiler /absolute/path/to/impellerc --render-shaders /absolute/path/to/render-shaders
```

`assets/shaders/SPATIAL-SOURCE.json` records the canonical math source. The implementation uses FP32 twelve-tap EASU and five-tap RCAS with individual texel-center samples on every backend. Reference: [AMD FidelityFX FSR 1.0.2](https://github.com/GPUOpen-Effects/FidelityFX-FSR/tree/a21ffb8f6c13233ba336352bdff293894c706575). Its MIT license is included and registered with Flutter when the optional bundle is loaded.
