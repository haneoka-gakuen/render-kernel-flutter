# Flutter render kernel

Shared Flutter GPU submission and frame lifecycle for independent renderers. The kernel loads textures, submits resource-driven render graphs and releases frame resources. It accepts numeric drawing contracts and has no application or game dependency.

`packages/render_contracts` contains the pure Dart geometry, matrices, view-facing lines and render graph contracts. It has no Flutter dependency. Vega and Cassiopeia select their own scene and chart compilers above this layer.

Run `flutter pub get` and `flutter analyze` from the repository root. Run `dart analyze` in `packages/render_contracts` to check the portable contracts.
