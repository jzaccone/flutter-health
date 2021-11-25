part of health;

/// Main class for the Plugin
class HealthFactory {
  static const MethodChannel _channel = MethodChannel('flutter_health');
  String? _deviceId;
  final _deviceInfo = DeviceInfoPlugin();

  static PlatformType _platformType =
      Platform.isAndroid ? PlatformType.ANDROID : PlatformType.IOS;

  /// Check if a given data type is available on the platform
  bool isDataTypeAvailable(HealthDataType dataType) =>
      _platformType == PlatformType.ANDROID
          ? _dataTypeKeysAndroid.contains(dataType)
          : _dataTypeKeysIOS.contains(dataType);

  /// Has permission been optained for the list of [HealthDataType]?
  ///
  /// iOS isn't completely supported by HealthKit, `false` means no, `true` means
  /// that the user has approved or declined permissions.
  /// In case user has declined permissions, reading using the [getHealthDataFromTypes]
  /// method will just return empty list for declined data types.
  static Future<bool?> hasPermissions(List<HealthDataType> types) async {
    return await _channel.invokeMethod('hasPermissions', {
      "types": types.map((type) => _enumToString(type)).toList(),
    });
  }

  /// Request permissions.
  ///
  /// If you're using more than one [HealthDataType] it's advised to call
  /// [requestPermissions] with all the data types once. Otherwise iOS HealthKit
  /// will ask to approve every permission one by one in separate screens.
  static Future<bool?> requestPermissions(List<HealthDataType> types) async {
    return await _channel.invokeMethod('requestPermissions', {
      "types": types.map((type) => _enumToString(type)).toList(),
    });
  }

  /// iOS isn't supported by HealthKit, method does nothing.
  static Future<void> revokePermissions() async {
    return await _channel.invokeMethod('revokePermissions');
  }

  /// Request access to GoogleFit or Apple HealthKit
  Future<bool> requestAuthorization(List<HealthDataType> types) async {
    /// If BMI is requested, then also ask for weight and height
    if (types.contains(HealthDataType.BODY_MASS_INDEX)) {
      if (!types.contains(HealthDataType.WEIGHT)) {
        types.add(HealthDataType.WEIGHT);
      }

      if (!types.contains(HealthDataType.HEIGHT)) {
        types.add(HealthDataType.HEIGHT);
      }
    }

    List<String> keys = types.map((e) => _enumToString(e)).toList();
    final bool isAuthorized =
        await _channel.invokeMethod('requestAuthorization', {'types': keys});
    return isAuthorized;
  }

  /// Calculate the BMI using the last observed height and weight values.
  Future<List<HealthDataPoint>> _computeAndroidBMI(
      DateTime startDate, DateTime endDate) async {
    List<HealthDataPoint> heights =
        await _prepareQuery(startDate, endDate, HealthDataType.HEIGHT);

    if (heights.isEmpty) {
      return [];
    }

    List<HealthDataPoint> weights =
        await _prepareQuery(startDate, endDate, HealthDataType.WEIGHT);

    double h = heights.last.value.toDouble();

    const dataType = HealthDataType.BODY_MASS_INDEX;
    final unit = _dataTypeToUnit[dataType]!;

    final bmiHealthPoints = <HealthDataPoint>[];
    for (var i = 0; i < weights.length; i++) {
      final bmiValue = weights[i].value.toDouble() / (h * h);
      final x = HealthDataPoint(bmiValue, dataType, unit, weights[i].dateFrom,
          weights[i].dateTo, _platformType, _deviceId!, '', '');

      bmiHealthPoints.add(x);
    }
    return bmiHealthPoints;
  }

  ///
  /// Saves health data into the HealthKit or Google Fit store
  ///
  /// Returns a Future of true if successful, a Future of false otherwise
  /// 
  /// Parameters
  /// 
  /// [value]  
  ///   value of the health data in double
  /// [type]   
  ///   the value's HealthDataType 
  /// [startTime] 
  ///   a DateTime object that specifies the start time when this data value is measured. 
  ///   It must be equal to or earlier than [endTime]
  /// [endTime]
  ///   a DateTime object that specifies the end time when this value is measured.
  ///   It must be equal to or later than [startTime].
  ///   Simply set [endTime] equal to [startTime] 
  ///   if the value is measured only at a specific point in time.
  /// 
  Future<bool> writeHealthData(double value, HealthDataType type,
      DateTime startTime, DateTime endTime) async {
    if (startTime.isAfter(endTime))
      throw ArgumentError("startTime must be equal or earlier than endTime");
    Map<String, dynamic> args = {
      'value': value,
      'dataTypeKey': _enumToString(type),
      'startTime': startTime.millisecondsSinceEpoch,
      'endTime': endTime.millisecondsSinceEpoch
    };
    bool? success = await _channel.invokeMethod('writeData', args);
    return success ?? false;
  }

  Future<List<HealthDataPoint>> getHealthDataFromTypes(
      DateTime startDate, DateTime endDate, List<HealthDataType> types) async {
    List<HealthDataPoint> dataPoints = [];

    for (var type in types) {
      final result = await _prepareQuery(startDate, endDate, type);
      dataPoints.addAll(result);
    }
    return removeDuplicates(dataPoints);
  }

  /// Prepares a query, i.e. checks if the types are available, etc.
  Future<List<HealthDataPoint>> _prepareQuery(
      DateTime startDate, DateTime endDate, HealthDataType dataType) async {
    // Ask for device ID only once
    _deviceId ??= _platformType == PlatformType.ANDROID
        ? (await _deviceInfo.androidInfo).androidId
        : (await _deviceInfo.iosInfo).identifierForVendor;

    // If not implemented on platform, throw an exception
    if (!isDataTypeAvailable(dataType)) {
      throw _HealthException(
          dataType, 'Not available on platform $_platformType');
    }

    // If BodyMassIndex is requested on Android, calculate this manually
    if (dataType == HealthDataType.BODY_MASS_INDEX &&
        _platformType == PlatformType.ANDROID) {
      return _computeAndroidBMI(startDate, endDate);
    }
    return await _dataQuery(startDate, endDate, dataType);
  }

  /// The main function for fetching health data
  Future<List<HealthDataPoint>> _dataQuery(
      DateTime startDate, DateTime endDate, HealthDataType dataType) async {
    // Set parameters for method channel request
    final args = <String, dynamic>{
      'dataTypeKey': _enumToString(dataType),
      'startDate': startDate.millisecondsSinceEpoch,
      'endDate': endDate.millisecondsSinceEpoch
    };

    final unit = _dataTypeToUnit[dataType]!;

    final fetchedDataPoints = await _channel.invokeMethod('getData', args);
    if (fetchedDataPoints != null) {
      return fetchedDataPoints.map<HealthDataPoint>((e) {
        final num value = e['value'];
        final DateTime from =
            DateTime.fromMillisecondsSinceEpoch(e['date_from']);
        final DateTime to = DateTime.fromMillisecondsSinceEpoch(e['date_to']);
        final String sourceId = e["source_id"];
        final String sourceName = e["source_name"];
        return HealthDataPoint(
          value,
          dataType,
          unit,
          from,
          to,
          _platformType,
          _deviceId!,
          sourceId,
          sourceName,
        );
      }).toList();
    } else {
      return <HealthDataPoint>[];
    }
  }

  /// Given an array of [HealthDataPoint]s, this method will return the array
  /// without any duplicates.
  static List<HealthDataPoint> removeDuplicates(List<HealthDataPoint> points) {
    final unique = <HealthDataPoint>[];

    for (var p in points) {
      var seenBefore = false;
      for (var s in unique) {
        if (s == p) {
          seenBefore = true;
        }
      }
      if (!seenBefore) {
        unique.add(p);
      }
    }
    return unique;
  }
}
