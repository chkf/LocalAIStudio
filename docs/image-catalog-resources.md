# Bundled image catalog resources

`Resources/models.json` and `Resources/configs.json` are copied without modification from
[`drawthingsai/draw-things-community`](https://github.com/drawthingsai/draw-things-community)
at commit `d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66`, the revision used by the pinned
MediaGenerationKit dependency.

Original paths:

- `Libraries/MediaGenerationKit/Resources/models.json`
- `Libraries/MediaGenerationKit/Resources/configs.json`

These files contain catalog entries and recommended generation settings, not model weights.
The upstream repository supplies a GPL-3.0 license, preserved locally as
[draw-things-catalog-LICENSE.md](draw-things-catalog-LICENSE.md); see the
[upstream license](https://github.com/drawthingsai/draw-things-community/blob/d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66/LICENSE.md).
Model weights remain separate downloads and retain their respective licenses.

The pinned resource loader searches `Bundle.main` and then its source directory. The source
directory does not exist on installed iPhones, so `project.yml` copies both JSON files into
the app bundle. This lets catalog resolution and recommended settings work without relying
on a network catalog fetch. Missing model weights still require an explicit resource preparation
step and a working download connection.
