# Segmeris bundled font sources

Only `google/GoogleSansFlex.ttf` and the three `huawei/HarmonyOS_Sans_SC_*.ttf` files are referenced by pubspec.yaml. Files already present at the root of this directory, including manifest.json and similarly named user fonts, have been preserved unchanged and are not bundled. No Noto font is substituted for HarmonyOS Sans.

## Huawei HarmonyOS Sans SC

Official resource listing: https://developer.huawei.com/consumer/cn/design/resource-V1/

Official archive: https://developer.huawei.com/images/download/general/HarmonyOS-Sans.zip

Archive size: 52,165,952 bytes. SHA-256: `fb02c86e358cd9aad8d4dfa957ee502381e7ee2e94499a9133add4324b6ce69a`.

The files were extracted without font conversion, subsetting, metadata edits or other binary modifications from `HarmonyOS Sans/HarmonyOS_Sans_SC/`:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| HarmonyOS_Sans_SC_Regular.ttf | 8261128 | 297b088424be212207df2ce8b98e335468b782aa6b96832af0b8b773d711e2b1 |
| HarmonyOS_Sans_SC_Medium.ttf | 8227312 | 6ed1553edccddc48eb27ff25d134a4a715cf54211238d4840b3038576cba1944 |
| HarmonyOS_Sans_SC_Bold.ttf | 8158996 | 43a424b85e47fb53a17b3b32026a71801f86f8e022ca6798d186b47d39fa5f01 |
| LICENSE.txt | 32768 | b2ffec0e6269ee41c3b5fc0345ab37600b46d66ebea6c9c58ff37f517bdfa164 |

Copyright 2021 Huawei Device Co., Ltd. The complete original **HarmonyOS Sans Fonts License Agreement** is in `huawei/LICENSE.txt`. This is Huawei's custom agreement, not the SIL OFL. It permits unmodified fonts to be embedded and bundled with application software; it requires a prominent in-app notice and retention of the copyright and complete agreement, forbids modifications, and prohibits standalone font redistribution/sale. The original license has trailing NUL padding; the license screen omits only those padding characters for display. The original file is kept intact.

Segmeris displays a permanent font acknowledgment in Settings and registers the complete agreement with Flutter's license screen. Huawei fonts remain unmodified in release assets.

## Google Sans Flex

Official Google Fonts directory: https://github.com/google/fonts/tree/main/ofl/googlesansflex

Original binary: https://github.com/google/fonts/blob/main/ofl/googlesansflex/GoogleSansFlex%5BROND%2Copsz%2Cslnt%2Cwdth%2Cwght%5D.ttf

The binary is stored as `google/GoogleSansFlex.ttf` for a simple asset path; its contents are unchanged. Git blob: `1d8d8ae5a7c6d0e48312d2a0a478bad92caee73a`. Size: 3,910,784 bytes. SHA-256: `a9ac770798857d5e8ac593ced42b22e40a7c08cec98319f92b0eccc2783a77ba`.

The official `METADATA.pb` records upstream https://github.com/googlefonts/googlesans-flex at commit `cedf1e9cef08ddf33d711dd259601ea3017b7cd4` and release v5.000. The original OFL.txt and TRADEMARKS.md are included. Google Sans Flex is licensed under the SIL Open Font License 1.1; using the font does not imply Google affiliation or sponsorship. The original license copyright line reads “Copyright 2015 The Google Sans Flex Authors”; the metadata's font copyright reads 2025. Both upstream files are retained as published.

## Mixed typography

The optional theme sets Google Sans Flex as the primary family and HarmonyOS Sans SC as its first fallback. Latin glyphs therefore use Google Sans Flex; Chinese Han glyphs missing from Google Sans Flex use the actual Huawei font. Characters outside these fonts continue through Flutter's platform fallbacks. The system-default option does not force either bundled family. Font sizes and accessibility text scaling remain controlled by Flutter.

## Material and motion implementation references

- Material 3 defaults: https://api.flutter.dev/flutter/material/ThemeData/useMaterial3.html
- Dynamic color variants: https://api.flutter.dev/flutter/material/DynamicSchemeVariant.html
- Flutter Material 3 support: https://docs.flutter.dev/ui/design/material
- Official Expressive tracker: https://github.com/flutter/flutter/issues/168813
- Documented spring limitation: https://api.flutter.dev/flutter/material/FadeForwardsPageTransitionsBuilder/kTransitionMilliseconds-constant.html

Validated against the installed Flutter 3.47.9 SDK (Dart 3.13.7). The application uses Flutter Material 3 widgets, theme extensions and duration/easing tokens. `DynamicSchemeVariant.expressive` is a palette option; it does not enable the complete Material 3 Expressive component/motion system. The SDK explicitly documents that native Android's Expressive springs are not currently supported in its fade-forwards transition. Segmeris does not modify the system renderer or provide a separate rendering engine.
