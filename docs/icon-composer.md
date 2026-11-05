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

The icon is integrated with the application and tests in PR #1. `project.yml`
registers `Resources/AppIcon.icon` as a resource and selects `AppIcon` as the
application icon. Build with Xcode 27 and XcodeGen as described in the README.

The combined workflow keeps the application's existing automatic triggers:
pull requests targeting `main` build an unsigned IPA and run simulator tests;
pushes to `main` build an unsigned IPA without re-running tests. It uses one
Xcode 27 job, not a second macOS job for the icon. The app build compiles the
icon into its asset catalog. Packaging checks that the IPA contains a nonempty
`Assets.car` and that the primary icon is registered as `AppIcon`.

After uploading the IPA, the same job exports Default, Dark, TintedLight,
TintedDark, ClearLight, and ClearDark previews at 1024 × 1024, plus an iOS 26
Default comparison. The artifacts are:

- **LocalAIStudio-unsigned**: the complete unsigned IPA, including the compiled icon.
- **LocalAIStudio-IconComposer**: the editable `.icon` source and seven previews.

The preview artifact is not an installable IPA and no longer includes a
separate `Assets.car` or partial Info.plist. For a Home Screen check, extract
the IPA from its artifact ZIP, sign it locally, and install it on the iPhone.
No signing material is needed in GitHub.

## Rendering and verification

The unchanged icon source was compiled and rendered on Xcode 27.1 in
[icon run #19](https://github.com/chkf/LocalAIStudio/actions/runs/41458503241).
That result verifies the icon source, not a full build of the combined PR.
The app's deployment target remains iOS 26; the additional iOS 26 preview
checks the earlier system design generation.

Ordinary SVG previews show the vector geometry, colors, and fixed reflection
details. They do not include Apple's glass material. `ictool` exports include
Apple's material rendering, but Clear previews do not reproduce the live Home
Screen wallpaper interaction. The vector version must be judged from those
rendered exports and an iPhone, not described as pixel-identical to the original
image. Live Home Screen behavior has not been verified on an iPhone.

## References

- [Apple: Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [GitHub: Xcode 27 runner image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
