# DH Barcode Generator (Flutter)

Flutter application that uses the device camera to capture a product photo, recognises the text on the label with Google ML Kit, and renders a Code 128 barcode for the detected product identifier.

## Features

- Live camera preview with capture support (using the `camera` plugin).
- On-device text recognition powered by `google_mlkit_text_recognition`.
- Automatic selection of the first SKU-like line (numeric/alphanumeric with digits).
- Barcode rendering via `barcode_widget` with optional view of the full recognised text.
- Runtime permission handling with `permission_handler`.

## Getting Started

1. Ensure the Flutter SDK is installed and on your `PATH` (`flutter --version` should succeed).
2. Fetch dependencies:
   ```bash
   flutter pub get
   ```
3. Run on a connected Android device (ensure USB debugging is enabled) or emulator:
   ```bash
   flutter run
   ```
   Grant camera permission when prompted.

To build and install the Android release manually:
```bash
flutter build apk --release
flutter install
```

## Notable Files

- `lib/main.dart` – Camera preview, capture flow, text recognition, and barcode UI.
- `pubspec.yaml` – Flutter dependencies (`camera`, `google_mlkit_text_recognition`, `barcode_widget`, `permission_handler`).
- `android/app/src/main/AndroidManifest.xml` – Declares camera permission.
- `ios/Runner/Info.plist` – Provides the iOS camera usage description.

## Next Ideas

- Allow manual selection/editing of the detected product code prior to barcode generation.
- Persist a history of scanned products and share generated barcodes.
- Support multiple barcode formats based on detected text patterns.
