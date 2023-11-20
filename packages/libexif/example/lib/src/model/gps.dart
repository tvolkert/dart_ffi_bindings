class GpsCoordinates {
  const GpsCoordinates(this.latitude, this.longitude);
  GpsCoordinates.fromList(List<double> values) : latitude = values.first, longitude = values.last;
  GpsCoordinates.fromString(String value) : this.fromList(value.split(', ').map<double>(double.parse).toList());

  final double latitude;
  final double longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  bool operator ==(Object other) {
    return other is GpsCoordinates
        && other.latitude == latitude
        && other.longitude == longitude;
  }

  @override
  String toString() => 'GpsCoordinates($latitude, $longitude)';
}
