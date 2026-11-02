# Local AI Studio app icon

`Resources/AppIcon.icon` is the editable Apple Icon Composer source. Its four
1024 × 1024 SVG layers are ordered front to back:

1. `04-AI.svg`: outlined dark blue-gray lettering; glass effects disabled.
2. `03-FrostedGlass.svg`: the pale central lens.
3. `02-GreenGlass.svg`: the green rear lens.
4. `01-BlueGlass.svg`: the blue rear lens.

The glass layers contain their own shapes and colors, with no embedded PNG,
background rectangle, or duplicated AI lettering. Icon Composer applies
specular highlights, refraction, translucency, and shadows to the three glass
groups independently. The selected raster reference remains at
`docs/app-icon-reference.png`; it is not packaged as an icon layer.

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

The source uses Icon Composer's `refractivity` feature and therefore requires
the Xcode 27 toolchain. The app's deployment target remains iOS 26. Refraction
has no visible effect on iOS versions earlier than 27; the system still renders
the supported glass properties and fallbacks.

Ordinary SVG previews show geometry and color only. They are not previews of
Apple's glass material. `ictool` exports include Apple's material rendering,
but Clear previews do not reproduce the live Home Screen wallpaper interaction.
The vector version must be judged from those rendered exports and an iPhone,
not described as pixel-identical to the original image.

## References

- [Apple: Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [GitHub: Xcode 27 runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
