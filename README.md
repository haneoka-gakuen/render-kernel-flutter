# Flutter render kernel

Shared Flutter GPU submission and frame lifecycle for independent renderers. It loads textures, submits resource-driven render graphs and releases frame resources, and it holds no game or application logic.

| Path | Contents |
| --- | --- |
| `lib` | GPU kernel, used by the Vega and Cassiopeia renderers |
| `packages/render_contracts` | Pure Dart geometry, matrices and render graph contracts, with no Flutter dependency |
| [SPATIAL-UPSCALING.md](SPATIAL-UPSCALING.md) | Optional FSR 1 upscaling |

## Development

```sh
flutter pub get
flutter analyze
cd packages/render_contracts && dart analyze
```

## License

[MPL-2.0](LICENSE). FidelityFX FSR terms are in [LICENSE-FidelityFX-FSR.txt](LICENSE-FidelityFX-FSR.txt).
