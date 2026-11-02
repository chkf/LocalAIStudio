# Local AI Studio app icon

`Resources/AppIcon.icon` is the editable Apple Icon Composer source. It has two
overlapping glossy lenses and separate lettering. Its three 1024 × 1024
SVG layers are ordered front to back:

1. `04-AI.svg`: outlined dark blue-gray lettering; glass effects disabled.
2. `02-GreenGlass.svg`: the green lens, including pearlescent overlap shading.
3. `01-BlueGlass.svg`: the blue lens continuing behind the green lens.

The two full freeform contours follow the chosen reference. Their geometric
intersection defines the central pearlescent region; there is no third physical
lens or separate frosted material group. The overlap's warm peach, white, cyan,
and mint reflections are fixed vector shading inside the green lens, clipped
by the blue lens outline. They are not claimed to result from ordinary blue and
green alpha blending.

Each SVG supplies saturated body color, broad curved reflections, and varying
edge highlights that retain the reference's glass volume. Group opacity is 1
to preserve those colors. Icon Composer adds native specular highlights and a
small layer-colored shadow. Directional translucency remains off; refraction
is disabled because it introduced hooks at the crossing points. The artwork
contains no embedded PNG, background rectangle, live font, or duplicated AI
lettering.

`docs/app-icon-reference.png` remains as the earlier color and composition
reference. The current design follows the reference's glossy curved surfaces
and two-lens overlap direction; the raster is not packaged as an icon layer.

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
