# Local AI Studio app icon

`Resources/AppIcon.icon` is the editable Apple Icon Composer source. It has two
overlapping translucent lenses and separate lettering. Its three 1024 × 1024
SVG layers are ordered front to back:

1. `04-AI.svg`: outlined dark blue-gray lettering, light ink in Dark and Mono
   appearances; glass effects disabled.
2. `02-GreenGlass.svg`: the green lens, with group opacity 0.54.
3. `01-BlueGlass.svg`: the blue lens, with group opacity 0.66.

The central color comes from the blue and green layers compositing through
each other. There is no third lens, separately painted overlap, or frosted
panel. The two shapes extend inward so their intersection frames the AI.

The SVGs contain opaque base colors with soft local reflection and edge details;
Icon Composer's group opacity creates the uniform transparency. Directional
material translucency is disabled to keep it separate from opacity. Refraction,
specular rims, and cast shadows are disabled: refraction caused visible hooks
at the two crossing points, while bright rims made the boundaries too hard.
The artwork contains no embedded PNG, background rectangle, or duplicated AI
lettering.

`docs/app-icon-reference.png` remains as the earlier color and composition
reference. The current design follows the clarified two-lens overlap direction;
the raster is not packaged as an icon layer.

## Compile and inspect

Pull requests that change the icon source, project resource wiring, or this
workflow automatically run the lightweight icon job. The full IPA job is
skipped for this icon PR. This follows the project's later decision to enable
automatic checks after making the repository public.

The manual entry remains available: run **Build unsigned iOS IPA** on
`codex/liquid-glass-app-icon` with **icon_only** checked. The icon job uses
Xcode 27 to:

- Compile `Assets.car`, the fallback app icon images, and the partial Info.plist.
- Export Apple-rendered Default, Dark, TintedLight, TintedDark, ClearLight, and
  ClearDark previews at 1024 × 1024.
- Export an additional iOS 26 Default preview for system-version comparison.
- Upload the compiled files, previews, and editable source together as
  **LocalAIStudio-IconComposer**.

The icon-only artifact is not an installable IPA. For a Home Screen check, run
the full build with **icon_only** unchecked, sign the resulting IPA locally,
and install it on the iPhone. No signing material is needed in GitHub.

## Rendering and verification

The source is validated with Xcode 27 and retains that toolchain's material
schema, with refraction disabled. The app's deployment target remains iOS 26;
the additional iOS 26 preview checks the earlier system design generation.

Ordinary SVG previews show the vector geometry, colors, and fixed reflection
details. They do not include Apple's glass material. `ictool` exports include
Apple's material rendering, but Clear previews do not reproduce the live Home
Screen wallpaper interaction.
The vector version must be judged from those rendered exports and an iPhone,
not described as pixel-identical to the original image.

## References

- [Apple: Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [GitHub: Xcode 27 runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
