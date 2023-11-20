import 'dart:io' show FileSystemException;
import 'dart:math' as math;
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:libexif/libexif.dart';
import 'package:libjpeg/libjpeg.dart';

import 'src/extensions/double.dart';
import 'src/model/exceptions.dart';
import 'src/model/gps.dart';

typedef NativeForEachContentCallback = Void Function(Pointer<ExifContent>, Pointer<Void>);
typedef NativeForEachEntryCallback = Void Function(Pointer<ExifEntry>, Pointer<Void>);
typedef ForEachEntryCallback = void Function(Pointer<ExifEntry>, Pointer<Void>);
typedef ExifDataVisitor<T> = T Function(Pointer<ExifData> nativeData);

late final LibExif libExif;
late final LibJpeg libJpeg;

main(List<String> args) {
  libExif = LibExif(DynamicLibrary.open('../libexif.dylib'));
  libJpeg = LibJpeg(DynamicLibrary.open('../libjpeg.dylib'));

  if (args.length > 1) {
    print('=== BEFORE ===');
  }
  printExifData(args.first);
  if (args.length > 1) {
    geotag(args.first, GpsCoordinates.fromString(args.last));
    print('=== AFTER ===');
    printExifData(args.first);
  }

  // visitExifData<void>(imagePath: args.first, visitor: (Pointer<ExifData> nativeData) {
  //   print(getValue(nativeData, ExifIfd.EXIF_IFD_GPS, 'GPSLatitude'));
  //   print(getValue(nativeData, ExifIfd.EXIF_IFD_GPS, 'GPSLongitude'));
  // });
}

void printExifData(String imagePath) {
  visitExifData<void>(imagePath: imagePath, visitor: (Pointer<ExifData> nativeData) {
    final Pointer<NativeFunction<NativeForEachContentCallback>> nativeContentCallback =
        Pointer.fromFunction<NativeForEachContentCallback>(printContent);
    libExif.exif_data_foreach_content(nativeData, nativeContentCallback, nullptr);
  });
}

void geotag(String imagePath, GpsCoordinates coords) {
  visitExifData<void>(imagePath: imagePath, visitor: (Pointer<ExifData> nativeData) {
    setGpsCoordinates(nativeData, coords);
    saveExifDataToFile(imagePath, nativeData);
  });
}

void saveExifDataToFile(String fileName, Pointer<ExifData> nativeData) {
  final List<String> parts = fileName.split('.');
  if (parts.length == 1) {
    throw UnsupportedImageFormatException(fileName);
  }

  switch (parts.last) {
    case 'jpg':
    case 'jpeg':
      saveExifDataToJpegFile(fileName, nativeData);
    case 'webp':
    case 'png':
    case 'tif':
    case 'tiff':
      throw UnimplementedError(parts.last);
    default:
      throw UnsupportedImageFormatException(parts.last);
  }
}

void saveExifDataToJpegFile(String fileName, Pointer<ExifData> nativeData) {
  assert(<String>{'jpg', 'jpeg'}.contains(fileName.split('.').last));
  final Pointer<JPEGData> nativeJpegData = libJpeg.jpeg_data_new();
  try {
    final Pointer<Char> nativeFileName = fileName.toNativeUtf8().cast<Char>();
    try {
      libJpeg.jpeg_data_load_file(nativeJpegData, nativeFileName);
      libJpeg.jpeg_data_set_exif_data(nativeJpegData, nativeData);
      final int saveResult = libJpeg.jpeg_data_save_file(nativeJpegData, nativeFileName);
      if (saveResult == 0) {
        // `jpeg_data_save_file` returns 1 on success, 0 on failure
        throw FileSystemException('Could not write data to ${fileName}');
      }
    } finally {
      malloc.free(nativeFileName);
    }
  } finally {
    libJpeg.jpeg_data_unref(nativeJpegData);
  }
}

GpsCoordinates? getGpsCoordinates(Pointer<ExifData> nativeData) {
  if (nativeData == nullptr) {
    return null;
  }
  final int byteOrder = libExif.exif_data_get_byte_order(nativeData);
  final Pointer<ExifContent> nativeContent = nativeData.ref.ifd[ExifIfd.EXIF_IFD_GPS];
  if (nativeContent == nullptr) {
    return null;
  }
  final double latitude = getLatLon(nativeContent, 'GPSLatitude', byteOrder);
  final double longitude = getLatLon(nativeContent, 'GPSLongitude', byteOrder);
  return GpsCoordinates(latitude, longitude);
}

void setGpsCoordinates(Pointer<ExifData> nativeData, GpsCoordinates coords) {
  assert(nativeData != nullptr);
  final Pointer<ExifContent> nativeContent = nativeData.ref.ifd[ExifIfd.EXIF_IFD_GPS];
  assert(nativeContent != nullptr);
  setLatLon(nativeContent, 'GPSLatitude', coords.latitude);
  setLatLon(nativeContent, 'GPSLongitude', coords.longitude);
}

double getLatLon(Pointer<ExifContent> nativeContent, String tagName, int byteOrder) {
  final Pointer<ExifEntry> nativeEntry = libExif.exif_content_get_entry(nativeContent, getTag(tagName));
  final String ref = getEntryValue(libExif.exif_content_get_entry(nativeContent, getTag('${tagName}Ref')));
  const Map<String, int> directions = <String, int>{'N': 1, 'S': -1, 'E': 1, 'W': -1};
  final int direction = directions[ref]!;
  try {
    double totalValue = 0;
    final int numComponents = nativeEntry.ref.components;
    for (int i = 0; i < numComponents; i++) {
      final int size = libExif.exif_format_get_size(nativeEntry.ref.format);
      final ExifRational nativeRational = libExif.exif_get_rational(
        nativeEntry.ref.data.elementAt(size * i),
        byteOrder,
      );
      final double level = math.pow(60, i).toDouble();
      final double incrementalValue = nativeRational.numerator / nativeRational.denominator;
      print('${nativeRational.numerator} / ${nativeRational.denominator}');
      totalValue += incrementalValue / level;
    }
    return totalValue * direction;
  } finally {
    //libExif.exif_entry_free(nativeEntry);
  }
}

void setLatLon(Pointer<ExifContent> nativeContent, String tagName, double value) {
  assert(nativeContent != nullptr);
  assert(tagName == 'GPSLatitude' || tagName == 'GPSLongitude');
  final Map<String, Map<bool, int>> directions = <String, Map<bool, int>>{
    'GPSLatitude': <bool, int>{
      true: 'N'.codeUnitAt(0),
      false: 'S'.codeUnitAt(0),
    },
    'GPSLongitude': <bool, int>{
      true: 'E'.codeUnitAt(0),
      false: 'W'.codeUnitAt(0),
    },
  };
  final int tag = getTag(tagName);
  Pointer<ExifEntry> nativeEntry = libExif.exif_content_get_entry(nativeContent, tag);
  if (nativeEntry == nullptr) {
    nativeEntry = libExif.exif_entry_new();
    libExif.exif_content_add_entry(nativeContent, nativeEntry);
    libExif.exif_entry_initialize(nativeEntry, tag);
  }

  final int refTag = getTag('${tagName}Ref');
  Pointer<ExifEntry> nativeRefEntry = libExif.exif_content_get_entry(nativeContent, refTag);
  if (nativeRefEntry == nullptr) {
    nativeRefEntry = libExif.exif_entry_new();
    libExif.exif_content_add_entry(nativeContent, nativeRefEntry);
    libExif.exif_entry_initialize(nativeRefEntry, refTag);
  }
  final int direction = directions[tagName]![value >= 0]!;
  final Pointer<UnsignedChar> nativeDirection = malloc<UnsignedChar>(sizeOf<UnsignedChar>())..value = direction;
  nativeRefEntry.ref
      ..data = nativeDirection
      ..size = 1
      ..components = 1
      ;
  value = value.abs();
  // malloc.free(nativeDirection);

  final int degrees = value.floor();
  value = 60 * (value - degrees);
  final int minutes = value.floor();
  value = 60 * (value - minutes);
  final double seconds = value.toPrecision(3);
  final List<(int, int)> components = <(int, int)>[
    (degrees, 1),
    (minutes, 1),
    ((seconds * 1000).toInt(), 1000),
  ];
  final int numComponents = nativeEntry.ref.components;
  final int size = libExif.exif_format_get_size(nativeEntry.ref.format);
  final int byteOrder = libExif.exif_data_get_byte_order(nativeContent.ref.parent);
  for (int i = 0; i < numComponents; i++) {
    final ExifRational nativeRational = libExif.exif_get_rational(
      nativeEntry.ref.data.elementAt(size * i),
      byteOrder,
    );
    nativeRational
        ..numerator = components[i].$1
        ..denominator = components[i].$2
        ;
    libExif.exif_set_rational(
      nativeEntry.ref.data.elementAt(size * i),
      byteOrder,
      nativeRational,
    );
  }
}

int getTag(String tagName) {
  final Pointer<Char> nativeTagName = tagName.toNativeUtf8().cast<Char>();
  final int tag = libExif.exif_tag_from_name(nativeTagName);
  malloc.free(nativeTagName);
  return tag;
}

String? getValue(Pointer<ExifData> nativeData, int ifd, String tagName) {
  if (nativeData == nullptr) {
    return null;
  }
  final Pointer<ExifContent> nativeContent = nativeData.ref.ifd[ifd];
  final Pointer<ExifEntry> nativeEntry = libExif.exif_content_get_entry(nativeContent, getTag(tagName));
  try {
    return getEntryValue(nativeEntry);
  } finally {
    //libExif.exif_entry_free(nativeEntry);
  }
}

T visitExifData<T>({
  required String imagePath,
  required ExifDataVisitor<T> visitor,
  bool createDataIfMissing = true,
}) {
  final Pointer<ExifLoader> nativeLoader = libExif.exif_loader_new();
  final Pointer<Char> nativePath = imagePath.toNativeUtf8().cast<Char>();
  libExif.exif_loader_write_file(nativeLoader, nativePath);
  malloc.free(nativePath);
  Pointer<ExifData> nativeData = libExif.exif_loader_get_data(nativeLoader);
  libExif.exif_loader_unref(nativeLoader);
  if (nativeData == nullptr && createDataIfMissing) {
    nativeData = libExif.exif_data_new();
  }
  try {
    return visitor(nativeData);
  } finally {
    libExif.exif_data_free(nativeData);
  }
}

void printContent(Pointer<ExifContent> nativeContent, Pointer<Void> userData) {
  final int ifd = libExif.exif_content_get_ifd(nativeContent);
  final Pointer<Char> nativeName = libExif.exif_ifd_get_name(ifd);
  final String name = nativeName.cast<Utf8>().toDartString();
  print('$name:');
  final Pointer<NativeFunction<NativeForEachEntryCallback>> nativeEntryCallback =
      Pointer.fromFunction<NativeForEachEntryCallback>(printEntry);
  final Pointer<Int> nativeIfd = malloc<Int>(sizeOf<Int>())..value = ifd;
  libExif.exif_content_foreach_entry(nativeContent, nativeEntryCallback, nativeIfd.cast<Void>());
  malloc.free(nativeIfd);
}

void printEntry(Pointer<ExifEntry> nativeEntry, Pointer<Void> nativeUserData) {
  final Pointer<Int> nativeIfd = nativeUserData.cast<Int>();
  final String name = getEntryName(nativeEntry, nativeIfd.value);
  final String value = getEntryValue(nativeEntry);
  print('  $name : $value');
}

String getEntryName(Pointer<ExifEntry> nativeEntry, int ifd) {
  final Pointer<Char> nativeName = libExif.exif_tag_get_name_in_ifd(nativeEntry.ref.tag, ifd);
  return nativeName.cast<Utf8>().toDartString();
}

String getEntryValue(Pointer<ExifEntry> nativeEntry) {
  const int kb = 1024;
  Pointer<Char> nativeValue = malloc<Char>(kb);
  libExif.exif_entry_get_value(nativeEntry, nativeValue, kb);
  String value = nativeValue.cast<Utf8>().toDartString();
  malloc.free(nativeValue);
  return value;
}
