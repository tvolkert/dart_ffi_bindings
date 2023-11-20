class UnsupportedImageFormatException extends Error {
  UnsupportedImageFormatException(this.fileName);

  final String fileName;
}
